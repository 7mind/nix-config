//! Validated room topology. Built from a [`Config`] once at startup; the
//! rest of the system holds an `Arc<Topology>` and treats it as immutable.
//!
//! Responsibilities:
//!
//!   * **Validation:** every `parent` reference resolves; the parent
//!     graph is acyclic; every device referenced by a room exists in the
//!     catalog and has a compatible kind; group ids and friendly_names
//!     are unique; member references point at known lights. A (tap,
//!     button) pair MAY be claimed by more than one room — the runtime
//!     dispatches the press to every claiming room in turn — but a
//!     warning is logged so an accidentally-shared button is still
//!     visible at startup.
//!   * **Indexing:** fast lookups for the runtime hot path:
//!       - room lookup by name
//!       - room lookup by group friendly_name (incoming z2m group state)
//!       - device → bindings (incoming switch / tap / motion events)
//!       - transitive descendants per room (filtered to those with rules)
//!
//! Most validation logic mirrors the existing `defineRooms` validation in
//! `private/hosts/raspi5m/hue-lights-tools.nix`. The intent is for the
//! Nix layer to keep doing its own structural validation (so bugs surface
//! at build time) and for the Rust layer to **also** run its own as a
//! defense-in-depth check at startup. They should agree; disagreement is
//! a bug.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use thiserror::Error;

use crate::config::{Config, DeviceCatalogEntry, Room, Trigger};

/// Stable name → resolved room data. Built from the raw `Config::rooms`
/// after validation; the controller indexes everything by room name.
pub type RoomName = String;

/// Friendly name of a tap, switch, light, or motion sensor.
pub type FriendlyName = String;

/// All the validation failures the topology builder can produce. Surfaced
/// as the daemon's startup error.
#[derive(Debug, Error, PartialEq)]
pub enum TopologyError {
    #[error("duplicate room name {0:?}")]
    DuplicateRoomName(RoomName),

    #[error("duplicate group id {id} (used by rooms {first:?} and {second:?})")]
    DuplicateGroupId {
        id: u8,
        first: RoomName,
        second: RoomName,
    },

    #[error("duplicate group friendly name {name:?} (used by rooms {first:?} and {second:?})")]
    DuplicateGroupName {
        name: FriendlyName,
        first: RoomName,
        second: RoomName,
    },

    #[error("room {room:?} has parent {parent:?} which is not a known room")]
    UnknownParent { room: RoomName, parent: RoomName },

    #[error("room {0:?} lists itself as parent")]
    SelfParent(RoomName),

    #[error("parent chain cycle: {chain}")]
    ParentChainCycle { chain: String },

    #[error("room {room:?} references device {device:?} which is not in the device catalog")]
    UnknownDevice {
        room: RoomName,
        device: FriendlyName,
    },

    #[error(
        "room {room:?} references device {device:?} as an input but it is a {kind} \
         (rooms can only bind switches, taps, and motion sensors as inputs)"
    )]
    WrongDeviceKind {
        room: RoomName,
        device: FriendlyName,
        kind: &'static str,
    },

    #[error("room {room:?} declares tap device {device:?} without a button number")]
    TapMissingButton {
        room: RoomName,
        device: FriendlyName,
    },

    #[error(
        "room {room:?} declares non-tap device {device:?} (kind {kind}) with a button \
         number — only Hue Tap devices have buttons"
    )]
    NonTapWithButton {
        room: RoomName,
        device: FriendlyName,
        kind: &'static str,
    },

    #[error(
        "room {room:?} member {member:?} references friendly name {bulb:?} which is \
         not a `light` in the catalog"
    )]
    UnknownMemberLight {
        room: RoomName,
        member: String,
        bulb: FriendlyName,
    },

    #[error(
        "room {room:?} member {member:?} is not in the form 'friendly_name/endpoint'"
    )]
    MalformedMember { room: RoomName, member: String },

    #[error(
        "scene schedule for room {room:?} is invalid: {source}"
    )]
    InvalidSceneSchedule {
        room: RoomName,
        #[source]
        source: crate::config::scenes::SceneScheduleError,
    },

    #[error("duplicate action rule name {0:?}")]
    DuplicateActionName(String),

    #[error(
        "action rule {rule:?} trigger references device {device:?} which is not in the catalog"
    )]
    ActionTriggerUnknownDevice { rule: String, device: String },

    #[error(
        "action rule {rule:?} trigger kind {trigger_kind} requires a {expected_kind} device \
         but {device:?} is a {actual_kind}"
    )]
    ActionTriggerWrongDeviceKind {
        rule: String,
        device: String,
        trigger_kind: &'static str,
        expected_kind: &'static str,
        actual_kind: &'static str,
    },

    #[error(
        "action rule {rule:?} effect targets device {device:?} which is not in the catalog"
    )]
    ActionEffectUnknownDevice { rule: String, device: String },

    #[error(
        "action rule {rule:?} effect targets device {device:?} which is a {kind} \
         (only plugs can be action targets)"
    )]
    ActionEffectNotPlug { rule: String, device: String, kind: &'static str },

    #[error(
        "action rule {rule:?} uses power_below trigger on device {device:?} which \
         lacks the \"power\" capability (variant: {variant})"
    )]
    ActionPowerBelowWithoutCapability {
        rule: String,
        device: String,
        variant: String,
    },
}

/// One tap button → room binding. The catalog lookup of the tap device
/// itself happens once at build time and isn't re-stored here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TapButtonBinding {
    pub device: FriendlyName,
    pub button: u8,
    pub room: RoomName,
}

/// One motion sensor → room binding. Carries the per-sensor settings the
/// controller needs at runtime (timeout, luminance gate). Lifted out of
/// the catalog so the controller doesn't have to keep doing catalog
/// lookups in the hot path.
#[derive(Debug, Clone)]
pub struct MotionBinding {
    pub sensor: FriendlyName,
    pub room: RoomName,
    pub occupancy_timeout_seconds: u32,
    pub max_illuminance: Option<u32>,
}

/// Validated, indexed view of one room. Holds everything the controller
/// needs at runtime — no follow-up catalog lookups required.
#[derive(Debug, Clone)]
pub struct ResolvedRoom {
    pub name: RoomName,
    pub group_name: FriendlyName,
    pub id: u8,
    pub members: Vec<String>,
    pub parent: Option<RoomName>,
    pub scenes: crate::config::SceneSchedule,
    pub off_transition_seconds: f64,
    pub motion_off_cooldown_seconds: u32,

    /// Friendly names of wall switches bound to this room. Empty if none.
    pub bound_switches: Vec<FriendlyName>,

    /// (tap, button) bindings claimed by this room. Empty if none.
    pub bound_taps: Vec<TapButtonBinding>,

    /// Motion sensors bound to this room. Empty if none.
    pub bound_motion: Vec<MotionBinding>,
}

impl ResolvedRoom {
    /// Quick check used by the runtime to gate motion-cooldown logic.
    pub fn has_motion_sensor(&self) -> bool {
        !self.bound_motion.is_empty()
    }

    /// True if any device (switch / tap / motion) is bound — i.e. this
    /// room has runtime rules. Rule-less rooms are still valid (the z2m
    /// group exists, scenes get provisioned), they just don't get
    /// invalidated when an ancestor fires (no per-room state to clear).
    pub fn has_rules(&self) -> bool {
        !self.bound_switches.is_empty()
            || !self.bound_taps.is_empty()
            || !self.bound_motion.is_empty()
    }
}

/// One resolved action rule, ready for runtime dispatch.
#[derive(Debug, Clone)]
pub struct ResolvedAction {
    pub name: String,
    pub trigger: Trigger,
    pub effect: crate::config::Effect,
}

/// The validated topology. Owned as `Arc<Topology>` by the daemon.
#[derive(Debug)]
pub struct Topology {
    rooms: BTreeMap<RoomName, ResolvedRoom>,
    /// group friendly_name → room name. The controller uses this to
    /// route incoming `zigbee2mqtt/<group>` state events to the right
    /// room.
    by_group_name: BTreeMap<FriendlyName, RoomName>,

    /// Wall-switch friendly_name → list of rooms it drives. A single
    /// switch can technically drive multiple rooms (the schema allows it),
    /// though in production each switch is bound to exactly one.
    switch_index: BTreeMap<FriendlyName, Vec<RoomName>>,

    /// (tap_friendly_name, button) → list of rooms it drives. The
    /// runtime dispatches each press to every room in the list, in the
    /// order they appear in the config. A list with more than one entry
    /// is allowed but unusual; the topology builder logs a warning so
    /// an accidental shared binding is visible at startup.
    tap_index: BTreeMap<(FriendlyName, u8), Vec<RoomName>>,

    /// Motion sensor friendly_name → list of rooms it drives. Same shape
    /// as `switch_index`; production has each sensor in one room.
    motion_index: BTreeMap<FriendlyName, Vec<RoomName>>,

    /// Transitive descendants per room. Filtered to descendants that
    /// have rules — rule-less rooms have no per-zone state, so propagating
    /// "physically_on" to them would be pointless.
    descendants_by_room: BTreeMap<RoomName, Vec<RoomName>>,

    /// Validated action rules, in config order.
    actions: Vec<ResolvedAction>,

    /// Switch action → action rule indexes. Keyed by switch
    /// friendly_name; value is a list of indexes into `actions`.
    action_switch_on_index: BTreeMap<FriendlyName, Vec<usize>>,
    action_switch_off_index: BTreeMap<FriendlyName, Vec<usize>>,

    /// Tap action → action rule indexes. Keyed by (tap, button).
    action_tap_index: BTreeMap<(FriendlyName, u8), Vec<usize>>,

    /// PowerBelow action rule indexes, keyed by plug device name.
    action_power_below_index: BTreeMap<FriendlyName, Vec<usize>>,

    /// All plug friendly_names from the device catalog.
    plug_names: BTreeSet<FriendlyName>,
}

impl Topology {
    /// Build and validate. Errors out on the first failure.
    pub fn build(config: &Config) -> Result<Self, TopologyError> {
        // 1. Index rooms by name and check for duplicates.
        let mut rooms_by_name: BTreeMap<RoomName, &Room> = BTreeMap::new();
        for room in &config.rooms {
            if rooms_by_name
                .insert(room.name.clone(), room)
                .is_some()
            {
                return Err(TopologyError::DuplicateRoomName(room.name.clone()));
            }
        }

        // 2. Group id and friendly name uniqueness.
        let mut id_owner: BTreeMap<u8, RoomName> = BTreeMap::new();
        let mut group_name_owner: BTreeMap<FriendlyName, RoomName> = BTreeMap::new();
        for room in &config.rooms {
            if let Some(prev) = id_owner.insert(room.id, room.name.clone()) {
                return Err(TopologyError::DuplicateGroupId {
                    id: room.id,
                    first: prev,
                    second: room.name.clone(),
                });
            }
            if let Some(prev) = group_name_owner.insert(room.group_name.clone(), room.name.clone()) {
                return Err(TopologyError::DuplicateGroupName {
                    name: room.group_name.clone(),
                    first: prev,
                    second: room.name.clone(),
                });
            }
        }

        // 3. Parent reference + cycle check.
        for room in &config.rooms {
            let Some(parent) = &room.parent else { continue };
            if parent == &room.name {
                return Err(TopologyError::SelfParent(room.name.clone()));
            }
            if !rooms_by_name.contains_key(parent) {
                return Err(TopologyError::UnknownParent {
                    room: room.name.clone(),
                    parent: parent.clone(),
                });
            }
        }
        // Walk each room's parent chain; fail if we revisit anything.
        for room in &config.rooms {
            let mut visited: Vec<RoomName> = vec![room.name.clone()];
            let mut current = room.parent.clone();
            while let Some(p) = current {
                if visited.contains(&p) {
                    visited.push(p);
                    return Err(TopologyError::ParentChainCycle {
                        chain: visited.join(" -> "),
                    });
                }
                visited.push(p.clone());
                current = rooms_by_name
                    .get(&p)
                    .and_then(|r| r.parent.clone());
            }
        }

        // 4. Scene schedule validation.
        for room in &config.rooms {
            room.scenes
                .validate()
                .map_err(|source| TopologyError::InvalidSceneSchedule {
                    room: room.name.clone(),
                    source,
                })?;
        }

        // 5. Member references must point at lights in the catalog.
        for room in &config.rooms {
            for member in &room.members {
                let (bulb, _endpoint) = parse_member_key(member).ok_or_else(|| {
                    TopologyError::MalformedMember {
                        room: room.name.clone(),
                        member: member.clone(),
                    }
                })?;
                match config.devices.get(bulb) {
                    Some(DeviceCatalogEntry::Light(_)) => { /* ok */ }
                    Some(other) => {
                        return Err(TopologyError::UnknownMemberLight {
                            room: room.name.clone(),
                            member: member.clone(),
                            bulb: format!(
                                "{} (catalog kind: {})",
                                bulb,
                                kind_label(other)
                            ),
                        });
                    }
                    None => {
                        return Err(TopologyError::UnknownMemberLight {
                            room: room.name.clone(),
                            member: member.clone(),
                            bulb: bulb.to_string(),
                        });
                    }
                }
            }
        }

        // 6. Device bindings: catalog membership, kind matching, button
        //    presence/absence. Tap (device, button) pairs MAY be shared
        //    across rooms — we collect every claimant and warn (not
        //    fail) if a pair has more than one.
        let mut tap_binding_owners: BTreeMap<(FriendlyName, u8), Vec<RoomName>> = BTreeMap::new();
        let mut switch_index: BTreeMap<FriendlyName, Vec<RoomName>> = BTreeMap::new();
        let mut motion_index: BTreeMap<FriendlyName, Vec<RoomName>> = BTreeMap::new();
        let mut bound_per_room: BTreeMap<
            RoomName,
            (Vec<FriendlyName>, Vec<TapButtonBinding>, Vec<MotionBinding>),
        > = BTreeMap::new();

        for room in &config.rooms {
            let entry = bound_per_room
                .entry(room.name.clone())
                .or_insert_with(|| (Vec::new(), Vec::new(), Vec::new()));

            for binding in &room.devices {
                let catalog = config.devices.get(&binding.device).ok_or_else(|| {
                    TopologyError::UnknownDevice {
                        room: room.name.clone(),
                        device: binding.device.clone(),
                    }
                })?;
                match catalog {
                    DeviceCatalogEntry::Light(_) => {
                        return Err(TopologyError::WrongDeviceKind {
                            room: room.name.clone(),
                            device: binding.device.clone(),
                            kind: "light",
                        });
                    }
                    DeviceCatalogEntry::Plug { .. } => {
                        return Err(TopologyError::WrongDeviceKind {
                            room: room.name.clone(),
                            device: binding.device.clone(),
                            kind: "plug",
                        });
                    }
                    DeviceCatalogEntry::Switch(_) => {
                        if binding.button.is_some() {
                            return Err(TopologyError::NonTapWithButton {
                                room: room.name.clone(),
                                device: binding.device.clone(),
                                kind: "switch",
                            });
                        }
                        entry.0.push(binding.device.clone());
                        switch_index
                            .entry(binding.device.clone())
                            .or_default()
                            .push(room.name.clone());
                    }
                    DeviceCatalogEntry::Tap(_) => {
                        let button = binding.button.ok_or_else(|| {
                            TopologyError::TapMissingButton {
                                room: room.name.clone(),
                                device: binding.device.clone(),
                            }
                        })?;
                        let key = (binding.device.clone(), button);
                        tap_binding_owners
                            .entry(key)
                            .or_default()
                            .push(room.name.clone());
                        entry.1.push(TapButtonBinding {
                            device: binding.device.clone(),
                            button,
                            room: room.name.clone(),
                        });
                    }
                    DeviceCatalogEntry::MotionSensor {
                        common: _,
                        occupancy_timeout_seconds,
                        max_illuminance,
                    } => {
                        if binding.button.is_some() {
                            return Err(TopologyError::NonTapWithButton {
                                room: room.name.clone(),
                                device: binding.device.clone(),
                                kind: "motion-sensor",
                            });
                        }
                        entry.2.push(MotionBinding {
                            sensor: binding.device.clone(),
                            room: room.name.clone(),
                            occupancy_timeout_seconds: *occupancy_timeout_seconds,
                            max_illuminance: *max_illuminance,
                        });
                        motion_index
                            .entry(binding.device.clone())
                            .or_default()
                            .push(room.name.clone());
                    }
                }
            }
        }

        // 7. Build resolved rooms now that all per-room data has been
        //    validated and split.
        let mut rooms: BTreeMap<RoomName, ResolvedRoom> = BTreeMap::new();
        for room in &config.rooms {
            let (bound_switches, bound_taps, bound_motion) = bound_per_room
                .remove(&room.name)
                .unwrap_or_else(|| (Vec::new(), Vec::new(), Vec::new()));
            rooms.insert(
                room.name.clone(),
                ResolvedRoom {
                    name: room.name.clone(),
                    group_name: room.group_name.clone(),
                    id: room.id,
                    members: room.members.clone(),
                    parent: room.parent.clone(),
                    scenes: room.scenes.clone(),
                    off_transition_seconds: room.off_transition_seconds,
                    motion_off_cooldown_seconds: room.motion_off_cooldown_seconds,
                    bound_switches,
                    bound_taps,
                    bound_motion,
                },
            );
        }

        // 8. group_name → room_name index.
        let by_group_name = rooms
            .values()
            .map(|r| (r.group_name.clone(), r.name.clone()))
            .collect();

        // 8b. Tap binding index. Each (tap, button) pair maps to one or
        //     more rooms; multi-room bindings get a startup warning so
        //     accidentally-shared buttons are visible without failing
        //     the build (the user might genuinely want one tap to drive
        //     several zones with a single press).
        let tap_index: BTreeMap<(FriendlyName, u8), Vec<RoomName>> = tap_binding_owners;
        for ((device, button), claiming_rooms) in &tap_index {
            if claiming_rooms.len() > 1 {
                tracing::warn!(
                    device = %device,
                    button,
                    rooms = ?claiming_rooms,
                    "tap (device, button) pair claimed by multiple rooms; \
                     each press will dispatch to every room in turn"
                );
            }
        }

        // 9. Transitive descendants. Walk each room and gather every
        //    room reachable via the *inverse* of the parent edge.
        //    Filter to descendants with rules so the controller doesn't
        //    waste cycles propagating to rule-less rooms.
        let mut direct_children: BTreeMap<RoomName, Vec<RoomName>> = BTreeMap::new();
        for room in rooms.values() {
            if let Some(parent) = &room.parent {
                direct_children
                    .entry(parent.clone())
                    .or_default()
                    .push(room.name.clone());
            }
        }
        let descendants_by_room = rooms
            .keys()
            .map(|name| {
                let mut out = Vec::new();
                let mut seen: HashSet<RoomName> = HashSet::new();
                let mut stack: Vec<RoomName> = direct_children
                    .get(name)
                    .cloned()
                    .unwrap_or_default();
                while let Some(curr) = stack.pop() {
                    if !seen.insert(curr.clone()) {
                        continue;
                    }
                    if let Some(room) = rooms.get(&curr) {
                        if room.has_rules() {
                            out.push(curr.clone());
                        }
                    }
                    if let Some(grandkids) = direct_children.get(&curr) {
                        stack.extend(grandkids.iter().cloned());
                    }
                }
                out.sort();
                (name.clone(), out)
            })
            .collect();

        // 10. Collect all plug names from the catalog.
        let plug_names: BTreeSet<FriendlyName> = config
            .devices
            .iter()
            .filter(|(_, entry)| entry.is_plug())
            .map(|(name, _)| name.clone())
            .collect();

        // 11. Validate action rules and build dispatch indexes.
        let mut action_names: BTreeSet<String> = BTreeSet::new();
        let mut actions: Vec<ResolvedAction> = Vec::new();
        let mut action_switch_on_index: BTreeMap<FriendlyName, Vec<usize>> = BTreeMap::new();
        let mut action_switch_off_index: BTreeMap<FriendlyName, Vec<usize>> = BTreeMap::new();
        let mut action_tap_index: BTreeMap<(FriendlyName, u8), Vec<usize>> = BTreeMap::new();
        let mut action_power_below_index: BTreeMap<FriendlyName, Vec<usize>> = BTreeMap::new();

        for rule in &config.actions {
            // Name uniqueness.
            if !action_names.insert(rule.name.clone()) {
                return Err(TopologyError::DuplicateActionName(rule.name.clone()));
            }

            // Validate trigger device.
            let trigger_device = rule.trigger.device();
            let trigger_entry = config.devices.get(trigger_device).ok_or_else(|| {
                TopologyError::ActionTriggerUnknownDevice {
                    rule: rule.name.clone(),
                    device: trigger_device.to_string(),
                }
            })?;

            match &rule.trigger {
                Trigger::Tap { device, button } => {
                    if !trigger_entry.is_tap() {
                        return Err(TopologyError::ActionTriggerWrongDeviceKind {
                            rule: rule.name.clone(),
                            device: device.clone(),
                            trigger_kind: "tap",
                            expected_kind: "tap",
                            actual_kind: kind_label(trigger_entry),
                        });
                    }
                    let idx = actions.len();
                    action_tap_index
                        .entry((device.clone(), *button))
                        .or_default()
                        .push(idx);
                }
                Trigger::SwitchOn { device } => {
                    if !trigger_entry.is_switch() {
                        return Err(TopologyError::ActionTriggerWrongDeviceKind {
                            rule: rule.name.clone(),
                            device: device.clone(),
                            trigger_kind: "switch_on",
                            expected_kind: "switch",
                            actual_kind: kind_label(trigger_entry),
                        });
                    }
                    let idx = actions.len();
                    action_switch_on_index
                        .entry(device.clone())
                        .or_default()
                        .push(idx);
                }
                Trigger::SwitchOff { device } => {
                    if !trigger_entry.is_switch() {
                        return Err(TopologyError::ActionTriggerWrongDeviceKind {
                            rule: rule.name.clone(),
                            device: device.clone(),
                            trigger_kind: "switch_off",
                            expected_kind: "switch",
                            actual_kind: kind_label(trigger_entry),
                        });
                    }
                    let idx = actions.len();
                    action_switch_off_index
                        .entry(device.clone())
                        .or_default()
                        .push(idx);
                }
                Trigger::PowerBelow { device, .. } => {
                    if !trigger_entry.is_plug() {
                        return Err(TopologyError::ActionTriggerWrongDeviceKind {
                            rule: rule.name.clone(),
                            device: device.clone(),
                            trigger_kind: "power_below",
                            expected_kind: "plug",
                            actual_kind: kind_label(trigger_entry),
                        });
                    }
                    if !trigger_entry.has_capability("power") {
                        let variant = match trigger_entry {
                            DeviceCatalogEntry::Plug { variant, .. } => variant.clone(),
                            _ => "unknown".into(),
                        };
                        return Err(TopologyError::ActionPowerBelowWithoutCapability {
                            rule: rule.name.clone(),
                            device: device.clone(),
                            variant,
                        });
                    }
                    let idx = actions.len();
                    action_power_below_index
                        .entry(device.clone())
                        .or_default()
                        .push(idx);
                }
            }

            // Validate effect target — must be a plug.
            let effect_target = rule.effect.target();
            let effect_entry = config.devices.get(effect_target).ok_or_else(|| {
                TopologyError::ActionEffectUnknownDevice {
                    rule: rule.name.clone(),
                    device: effect_target.to_string(),
                }
            })?;
            if !effect_entry.is_plug() {
                return Err(TopologyError::ActionEffectNotPlug {
                    rule: rule.name.clone(),
                    device: effect_target.to_string(),
                    kind: kind_label(effect_entry),
                });
            }

            actions.push(ResolvedAction {
                name: rule.name.clone(),
                trigger: rule.trigger.clone(),
                effect: rule.effect.clone(),
            });
        }

        Ok(Self {
            rooms,
            by_group_name,
            switch_index,
            tap_index,
            motion_index,
            descendants_by_room,
            actions,
            action_switch_on_index,
            action_switch_off_index,
            action_tap_index,
            action_power_below_index,
            plug_names,
        })
    }

    /// All resolved rooms, in stable name order.
    pub fn rooms(&self) -> impl Iterator<Item = &ResolvedRoom> {
        self.rooms.values()
    }

    /// Look up a room by its internal name.
    pub fn room_by_name(&self, name: &str) -> Option<&ResolvedRoom> {
        self.rooms.get(name)
    }

    /// Look up the room owning a z2m group friendly_name.
    pub fn room_by_group_name(&self, group_name: &str) -> Option<&ResolvedRoom> {
        self.by_group_name
            .get(group_name)
            .and_then(|n| self.rooms.get(n))
    }

    /// Rooms driven by a wall-switch friendly_name.
    pub fn rooms_for_switch(&self, switch: &str) -> &[RoomName] {
        self.switch_index
            .get(switch)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// Rooms bound to a (tap, button) pair. Empty if the pair is
    /// unclaimed; almost always a single-element slice; longer when
    /// the user has intentionally bound one button to several zones.
    pub fn rooms_for_tap_button(&self, tap: &str, button: u8) -> &[RoomName] {
        self.tap_index
            .get(&(tap.to_string(), button))
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// Rooms driven by a motion sensor friendly_name.
    pub fn rooms_for_motion(&self, sensor: &str) -> &[RoomName] {
        self.motion_index
            .get(sensor)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// Transitive descendants of `room` that have rules. Empty for leaf
    /// rooms or rooms whose only descendants are rule-less.
    pub fn descendants_of(&self, room: &str) -> &[RoomName] {
        self.descendants_by_room
            .get(room)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// All distinct group friendly names. Used by the daemon's startup
    /// state refresh to know which `zigbee2mqtt/<group>` topics to
    /// subscribe to.
    pub fn all_group_names(&self) -> Vec<&str> {
        self.rooms.values().map(|r| r.group_name.as_str()).collect()
    }

    /// All distinct switch friendly names. Used to subscribe to action
    /// topics.
    pub fn all_switch_names(&self) -> BTreeSet<&str> {
        self.switch_index.keys().map(String::as_str).collect()
    }

    /// All distinct tap friendly names.
    pub fn all_tap_names(&self) -> BTreeSet<&str> {
        self.tap_index.keys().map(|(d, _)| d.as_str()).collect()
    }

    /// All distinct motion sensor friendly names.
    pub fn all_motion_sensor_names(&self) -> BTreeSet<&str> {
        self.motion_index.keys().map(String::as_str).collect()
    }

    /// All plug device friendly names from the catalog.
    pub fn all_plug_names(&self) -> &BTreeSet<FriendlyName> {
        &self.plug_names
    }

    /// True if this device name is a known plug.
    pub fn is_plug(&self, device: &str) -> bool {
        self.plug_names.contains(device)
    }

    /// All resolved action rules.
    pub fn actions(&self) -> &[ResolvedAction] {
        &self.actions
    }

    /// Action rule indexes triggered by a switch "on" press.
    pub fn actions_for_switch_on(&self, switch: &str) -> &[usize] {
        self.action_switch_on_index
            .get(switch)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// Action rule indexes triggered by a switch "off" press.
    pub fn actions_for_switch_off(&self, switch: &str) -> &[usize] {
        self.action_switch_off_index
            .get(switch)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// Action rule indexes triggered by a tap button press.
    pub fn actions_for_tap(&self, tap: &str, button: u8) -> &[usize] {
        self.action_tap_index
            .get(&(tap.to_string(), button))
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// Action rule indexes with PowerBelow triggers for a plug device.
    pub fn actions_for_power_below(&self, plug: &str) -> &[usize] {
        self.action_power_below_index
            .get(plug)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }
}

/// Split a `"friendly_name/endpoint"` member key into its parts. Returns
/// `None` if the input doesn't contain a `/` or the endpoint isn't a
/// number. Mirrors hue-setup's `parse_member_key`.
fn parse_member_key(member: &str) -> Option<(&str, u32)> {
    let (name, endpoint) = member.rsplit_once('/')?;
    let endpoint: u32 = endpoint.parse().ok()?;
    Some((name, endpoint))
}

fn kind_label(entry: &DeviceCatalogEntry) -> &'static str {
    match entry {
        DeviceCatalogEntry::Light(_) => "light",
        DeviceCatalogEntry::Switch(_) => "switch",
        DeviceCatalogEntry::Tap(_) => "tap",
        DeviceCatalogEntry::MotionSensor { .. } => "motion-sensor",
        DeviceCatalogEntry::Plug { .. } => "plug",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{ActionRule, CommonFields, DeviceCatalogEntry, Effect, Room, Trigger};
    use crate::config::scenes::{Scene, SceneSchedule, Slot};
    use std::collections::BTreeMap;

    fn light(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Light(CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::new(),
        })
    }
    fn switch_dev(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Switch(CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::new(),
        })
    }
    fn tap_dev(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Tap(CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::new(),
        })
    }
    #[allow(dead_code)]
    fn motion(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::MotionSensor {
            common: CommonFields {
                ieee_address: ieee.into(),
                description: None,
                options: BTreeMap::new(),
            },
            occupancy_timeout_seconds: 60,
            max_illuminance: None,
        }
    }

    /// Trivial day-only scene schedule for tests that don't care about slots.
    fn day_scenes() -> SceneSchedule {
        SceneSchedule {
            scenes: vec![Scene {
                id: 1,
                name: "x".into(),
                state: "ON".into(),
                brightness: None,
                color_temp: None,
                transition: 0.0,
            }],
            slots: BTreeMap::from([(
                "day".into(),
                Slot {
                    start_hour: 0,
                    end_hour_exclusive: 24,
                    scene_ids: vec![1],
                },
            )]),
        }
    }

    fn room(
        name: &str,
        id: u8,
        members: Vec<&str>,
        devices: Vec<crate::config::DeviceBinding>,
        parent: Option<&str>,
    ) -> Room {
        Room {
            name: name.into(),
            group_name: format!("hue-lz-{name}"),
            id,
            members: members.into_iter().map(String::from).collect(),
            parent: parent.map(String::from),
            devices,
            scenes: day_scenes(),
            off_transition_seconds: 0.8,
            motion_off_cooldown_seconds: 0,
        }
    }

    fn binding(device: &str, button: Option<u8>) -> crate::config::DeviceBinding {
        crate::config::DeviceBinding {
            device: device.into(),
            button,
        }
    }

    fn plug_dev(ieee: &str, variant: &str, caps: &[&str]) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Plug {
            common: CommonFields {
                ieee_address: ieee.into(),
                description: None,
                options: BTreeMap::new(),
            },
            variant: variant.into(),
            capabilities: caps.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn config(devices: Vec<(&str, DeviceCatalogEntry)>, rooms: Vec<Room>) -> Config {
        config_with_actions(devices, rooms, vec![])
    }

    fn config_with_actions(
        devices: Vec<(&str, DeviceCatalogEntry)>,
        rooms: Vec<Room>,
        actions: Vec<ActionRule>,
    ) -> Config {
        let devices = devices
            .into_iter()
            .map(|(n, e)| (n.to_string(), e))
            .collect();
        Config {
            name_by_address: BTreeMap::new(),
            devices,
            rooms,
            actions,
            defaults: Default::default(),
        }
    }

    #[test]
    fn empty_config_builds() {
        let cfg = config(vec![], vec![]);
        let topo = Topology::build(&cfg).unwrap();
        assert!(topo.rooms().next().is_none());
    }

    #[test]
    fn single_switch_room_builds_and_indexes() {
        let cfg = config(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-s-a", switch_dev("0x1")),
            ],
            vec![room(
                "study",
                1,
                vec!["hue-l-a/11"],
                vec![binding("hue-s-a", None)],
                None,
            )],
        );
        let topo = Topology::build(&cfg).unwrap();
        let r = topo.room_by_name("study").unwrap();
        assert_eq!(r.bound_switches, vec!["hue-s-a"]);
        assert!(r.bound_taps.is_empty());
        assert!(r.bound_motion.is_empty());
        assert!(r.has_rules());

        assert_eq!(topo.rooms_for_switch("hue-s-a"), &["study".to_string()]);
        assert_eq!(topo.room_by_group_name("hue-lz-study").unwrap().name, "study");
    }

    #[test]
    fn tap_button_binding_routes_to_room() {
        let cfg = config(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-l-b", light("0xb")),
                ("hue-ts-foo", tap_dev("0x1")),
            ],
            vec![
                room(
                    "kitchen-cooker",
                    1,
                    vec!["hue-l-a/11"],
                    vec![binding("hue-ts-foo", Some(2))],
                    Some("kitchen-all"),
                ),
                room(
                    "kitchen-all",
                    2,
                    vec!["hue-l-a/11", "hue-l-b/11"],
                    vec![binding("hue-ts-foo", Some(1))],
                    None,
                ),
            ],
        );
        let topo = Topology::build(&cfg).unwrap();

        assert_eq!(
            topo.rooms_for_tap_button("hue-ts-foo", 1),
            &["kitchen-all".to_string()]
        );
        assert_eq!(
            topo.rooms_for_tap_button("hue-ts-foo", 2),
            &["kitchen-cooker".to_string()]
        );
        assert!(topo.rooms_for_tap_button("hue-ts-foo", 3).is_empty());
    }

    #[test]
    fn duplicate_group_id_rejected() {
        let cfg = config(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-l-b", light("0xb")),
                ("hue-s-a", switch_dev("0x1")),
                ("hue-s-b", switch_dev("0x2")),
            ],
            vec![
                room("a", 1, vec!["hue-l-a/11"], vec![binding("hue-s-a", None)], None),
                room("b", 1, vec!["hue-l-b/11"], vec![binding("hue-s-b", None)], None),
            ],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::DuplicateGroupId { id: 1, .. }));
    }

    #[test]
    fn duplicate_group_friendly_name_rejected() {
        let cfg = config(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-s-a", switch_dev("0x1")),
                ("hue-s-b", switch_dev("0x2")),
            ],
            vec![
                Room {
                    name: "a".into(),
                    group_name: "shared".into(),
                    id: 1,
                    members: vec!["hue-l-a/11".into()],
                    parent: None,
                    devices: vec![binding("hue-s-a", None)],
                    scenes: day_scenes(),
                    off_transition_seconds: 0.8,
                    motion_off_cooldown_seconds: 0,
                },
                Room {
                    name: "b".into(),
                    group_name: "shared".into(),
                    id: 2,
                    members: vec!["hue-l-a/11".into()],
                    parent: None,
                    devices: vec![binding("hue-s-b", None)],
                    scenes: day_scenes(),
                    off_transition_seconds: 0.8,
                    motion_off_cooldown_seconds: 0,
                },
            ],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(
            err,
            TopologyError::DuplicateGroupName { name, .. } if name == "shared"
        ));
    }

    #[test]
    fn unknown_parent_rejected() {
        let cfg = config(
            vec![("hue-l-a", light("0xa")), ("hue-s-a", switch_dev("0x1"))],
            vec![room(
                "child",
                1,
                vec!["hue-l-a/11"],
                vec![binding("hue-s-a", None)],
                Some("ghost"),
            )],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::UnknownParent { .. }));
    }

    #[test]
    fn self_parent_rejected() {
        let cfg = config(
            vec![("hue-l-a", light("0xa")), ("hue-s-a", switch_dev("0x1"))],
            vec![room(
                "loop",
                1,
                vec!["hue-l-a/11"],
                vec![binding("hue-s-a", None)],
                Some("loop"),
            )],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::SelfParent(_)));
    }

    #[test]
    fn parent_chain_cycle_rejected() {
        let cfg = config(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-l-b", light("0xb")),
                ("hue-s-a", switch_dev("0x1")),
                ("hue-s-b", switch_dev("0x2")),
            ],
            vec![
                room("a", 1, vec!["hue-l-a/11"], vec![binding("hue-s-a", None)], Some("b")),
                room("b", 2, vec!["hue-l-b/11"], vec![binding("hue-s-b", None)], Some("a")),
            ],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::ParentChainCycle { .. }));
    }

    #[test]
    fn unknown_device_rejected() {
        let cfg = config(
            vec![("hue-l-a", light("0xa"))],
            vec![room(
                "study",
                1,
                vec!["hue-l-a/11"],
                vec![binding("hue-s-ghost", None)],
                None,
            )],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::UnknownDevice { .. }));
    }

    #[test]
    fn light_in_devices_slot_rejected() {
        let cfg = config(
            vec![("hue-l-a", light("0xa"))],
            vec![room(
                "study",
                1,
                vec!["hue-l-a/11"],
                vec![binding("hue-l-a", None)],
                None,
            )],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(
            err,
            TopologyError::WrongDeviceKind { kind: "light", .. }
        ));
    }

    #[test]
    fn shared_tap_binding_routes_to_every_claiming_room() {
        // Same (tap, button) pair claimed by two rooms — used to be a
        // hard error, now allowed (with a startup warning emitted via
        // tracing). The runtime dispatches each press to every room.
        let cfg = config(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-l-b", light("0xb")),
                ("hue-ts-foo", tap_dev("0x1")),
            ],
            vec![
                room("a", 1, vec!["hue-l-a/11"], vec![binding("hue-ts-foo", Some(1))], None),
                room("b", 2, vec!["hue-l-b/11"], vec![binding("hue-ts-foo", Some(1))], None),
            ],
        );
        let topo = Topology::build(&cfg).unwrap();
        assert_eq!(
            topo.rooms_for_tap_button("hue-ts-foo", 1),
            &["a".to_string(), "b".to_string()]
        );
    }

    #[test]
    fn tap_without_button_rejected() {
        let cfg = config(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-ts-foo", tap_dev("0x1")),
            ],
            vec![room(
                "a",
                1,
                vec!["hue-l-a/11"],
                vec![binding("hue-ts-foo", None)],
                None,
            )],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::TapMissingButton { .. }));
    }

    #[test]
    fn switch_with_button_rejected() {
        let cfg = config(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-s-a", switch_dev("0x1")),
            ],
            vec![room(
                "a",
                1,
                vec!["hue-l-a/11"],
                vec![binding("hue-s-a", Some(1))],
                None,
            )],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(
            err,
            TopologyError::NonTapWithButton { kind: "switch", .. }
        ));
    }

    #[test]
    fn member_referencing_non_light_rejected() {
        let cfg = config(
            vec![("hue-s-a", switch_dev("0x1"))],
            vec![room(
                "a",
                1,
                vec!["hue-s-a/11"],
                vec![binding("hue-s-a", None)],
                None,
            )],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::UnknownMemberLight { .. }));
    }

    #[test]
    fn malformed_member_rejected() {
        let cfg = config(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-s-a", switch_dev("0x1")),
            ],
            vec![room(
                "a",
                1,
                vec!["hue-l-a"],
                vec![binding("hue-s-a", None)],
                None,
            )],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::MalformedMember { .. }));
    }

    #[test]
    fn plug_in_room_devices_rejected() {
        let cfg = config(
            vec![
                ("hue-l-a", light("0xa")),
                ("z2m-p-foo", plug_dev("0xf", "sonoff-power", &["on-off", "power"])),
            ],
            vec![room(
                "a",
                1,
                vec!["hue-l-a/11"],
                vec![binding("z2m-p-foo", None)],
                None,
            )],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::WrongDeviceKind { kind: "plug", .. }));
    }

    #[test]
    fn action_tap_toggle_builds_and_indexes() {
        let cfg = config_with_actions(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-ts-foo", tap_dev("0x1")),
                ("z2m-p-printer", plug_dev("0xf", "sonoff-power", &["on-off", "power"])),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![ActionRule {
                name: "printer-toggle".into(),
                trigger: Trigger::Tap { device: "hue-ts-foo".into(), button: 3 },
                effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-printer".into() },
            }],
        );
        let topo = Topology::build(&cfg).unwrap();
        assert_eq!(topo.actions().len(), 1);
        assert_eq!(topo.actions_for_tap("hue-ts-foo", 3), &[0]);
        assert!(topo.actions_for_tap("hue-ts-foo", 1).is_empty());
        assert!(topo.is_plug("z2m-p-printer"));
        assert!(!topo.is_plug("hue-l-a"));
    }

    #[test]
    fn action_switch_on_off_builds_and_indexes() {
        let cfg = config_with_actions(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-s-office", switch_dev("0x1")),
                ("z2m-p-lamp", plug_dev("0xf", "sonoff-basic", &["on-off"])),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![
                ActionRule {
                    name: "lamp-on".into(),
                    trigger: Trigger::SwitchOn { device: "hue-s-office".into() },
                    effect: Effect::TurnOn { target: "z2m-p-lamp".into() },
                },
                ActionRule {
                    name: "lamp-off".into(),
                    trigger: Trigger::SwitchOff { device: "hue-s-office".into() },
                    effect: Effect::TurnOff { target: "z2m-p-lamp".into() },
                },
            ],
        );
        let topo = Topology::build(&cfg).unwrap();
        assert_eq!(topo.actions().len(), 2);
        assert_eq!(topo.actions_for_switch_on("hue-s-office"), &[0]);
        assert_eq!(topo.actions_for_switch_off("hue-s-office"), &[1]);
    }

    #[test]
    fn action_power_below_builds_and_indexes() {
        let cfg = config_with_actions(
            vec![
                ("hue-l-a", light("0xa")),
                ("z2m-p-printer", plug_dev("0xf", "sonoff-power", &["on-off", "power"])),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![ActionRule {
                name: "printer-kill".into(),
                trigger: Trigger::PowerBelow {
                    device: "z2m-p-printer".into(),
                    watts: 5.0,
                    for_seconds: 300,
                },
                effect: Effect::TurnOff { target: "z2m-p-printer".into() },
            }],
        );
        let topo = Topology::build(&cfg).unwrap();
        assert_eq!(topo.actions_for_power_below("z2m-p-printer"), &[0]);
    }

    #[test]
    fn action_power_below_without_capability_rejected() {
        let cfg = config_with_actions(
            vec![
                ("hue-l-a", light("0xa")),
                ("z2m-p-basic", plug_dev("0xf", "sonoff-basic", &["on-off"])),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![ActionRule {
                name: "kill".into(),
                trigger: Trigger::PowerBelow {
                    device: "z2m-p-basic".into(),
                    watts: 5.0,
                    for_seconds: 300,
                },
                effect: Effect::TurnOff { target: "z2m-p-basic".into() },
            }],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::ActionPowerBelowWithoutCapability { .. }));
    }

    #[test]
    fn action_trigger_wrong_device_kind_rejected() {
        let cfg = config_with_actions(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-s-foo", switch_dev("0x1")),
                ("z2m-p-printer", plug_dev("0xf", "sonoff-power", &["on-off", "power"])),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![ActionRule {
                name: "bad".into(),
                trigger: Trigger::Tap { device: "hue-s-foo".into(), button: 1 },
                effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-printer".into() },
            }],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::ActionTriggerWrongDeviceKind { .. }));
    }

    #[test]
    fn action_effect_not_plug_rejected() {
        let cfg = config_with_actions(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-ts-foo", tap_dev("0x1")),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![ActionRule {
                name: "bad".into(),
                trigger: Trigger::Tap { device: "hue-ts-foo".into(), button: 1 },
                effect: Effect::Toggle { confirm_off_seconds: None, target: "hue-l-a".into() },
            }],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::ActionEffectNotPlug { .. }));
    }

    #[test]
    fn duplicate_action_name_rejected() {
        let cfg = config_with_actions(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-ts-foo", tap_dev("0x1")),
                ("z2m-p-a", plug_dev("0xf", "sonoff-basic", &["on-off"])),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![
                ActionRule {
                    name: "dupe".into(),
                    trigger: Trigger::Tap { device: "hue-ts-foo".into(), button: 1 },
                    effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-a".into() },
                },
                ActionRule {
                    name: "dupe".into(),
                    trigger: Trigger::Tap { device: "hue-ts-foo".into(), button: 2 },
                    effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-a".into() },
                },
            ],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::DuplicateActionName(_)));
    }

    #[test]
    fn action_trigger_unknown_device_rejected() {
        let cfg = config_with_actions(
            vec![
                ("hue-l-a", light("0xa")),
                ("z2m-p-a", plug_dev("0xf", "sonoff-basic", &["on-off"])),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![ActionRule {
                name: "bad".into(),
                trigger: Trigger::Tap { device: "ghost".into(), button: 1 },
                effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-a".into() },
            }],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::ActionTriggerUnknownDevice { .. }));
    }

    #[test]
    fn action_effect_unknown_device_rejected() {
        let cfg = config_with_actions(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-ts-foo", tap_dev("0x1")),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![ActionRule {
                name: "bad".into(),
                trigger: Trigger::Tap { device: "hue-ts-foo".into(), button: 1 },
                effect: Effect::Toggle { confirm_off_seconds: None, target: "ghost".into() },
            }],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::ActionEffectUnknownDevice { .. }));
    }

    #[test]
    fn descendants_filter_rule_less_rooms() {
        let cfg = config(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-l-b", light("0xb")),
                ("hue-l-c", light("0xc")),
                ("hue-s-cooker", switch_dev("0x1")),
                ("hue-s-all", switch_dev("0x2")),
            ],
            vec![
                room(
                    "kitchen-cooker",
                    1,
                    vec!["hue-l-a/11"],
                    vec![binding("hue-s-cooker", None)],
                    Some("kitchen-all"),
                ),
                // Rule-less child: no devices.
                room(
                    "kitchen-empty",
                    2,
                    vec!["hue-l-b/11"],
                    vec![],
                    Some("kitchen-all"),
                ),
                room(
                    "kitchen-all",
                    3,
                    vec!["hue-l-a/11", "hue-l-b/11", "hue-l-c/11"],
                    vec![binding("hue-s-all", None)],
                    None,
                ),
            ],
        );
        let topo = Topology::build(&cfg).unwrap();
        // Only kitchen-cooker has rules; kitchen-empty is filtered out.
        assert_eq!(
            topo.descendants_of("kitchen-all"),
            &["kitchen-cooker".to_string()]
        );
    }

    #[test]
    fn transitive_descendants_through_rule_less_intermediate() {
        // grandparent → parent (rule-less) → child (with rules)
        let cfg = config(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-l-b", light("0xb")),
                ("hue-l-c", light("0xc")),
                ("hue-s-child", switch_dev("0x1")),
                ("hue-s-grand", switch_dev("0x2")),
            ],
            vec![
                room(
                    "child",
                    1,
                    vec!["hue-l-a/11"],
                    vec![binding("hue-s-child", None)],
                    Some("parent"),
                ),
                room("parent", 2, vec!["hue-l-b/11"], vec![], Some("grand")),
                room(
                    "grand",
                    3,
                    vec!["hue-l-c/11"],
                    vec![binding("hue-s-grand", None)],
                    None,
                ),
            ],
        );
        let topo = Topology::build(&cfg).unwrap();
        // grand's descendants: child (parent is rule-less, filtered out)
        assert_eq!(topo.descendants_of("grand"), &["child".to_string()]);
        // parent's descendants: child
        assert_eq!(topo.descendants_of("parent"), &["child".to_string()]);
    }
}
