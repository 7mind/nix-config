//! Validated room topology. Built from a [`Config`] once at startup; the
//! rest of the system holds an `Arc<Topology>` and treats it as immutable.
//!
//! Responsibilities:
//!
//!   * **Validation:** every `parent` reference resolves; the parent
//!     graph is acyclic; every device referenced by a binding exists in the
//!     catalog and has a compatible kind; group ids and friendly_names
//!     are unique; member references point at known lights.
//!   * **Indexing:** fast lookups for the runtime hot path:
//!       - room lookup by name
//!       - room lookup by group friendly_name (incoming z2m group state)
//!       - (device, button, gesture) → binding indexes (incoming switch events)
//!       - motion sensor → rooms (incoming motion events)
//!       - transitive descendants per room (filtered to those with rules)
//!
//! Most validation logic mirrors the existing `defineRooms` validation in
//! `private/hosts/raspi5m/mqtt-controller-tools.nix`. The intent is for the
//! Nix layer to keep doing its own structural validation (so bugs surface
//! at build time) and for the Rust layer to **also** run its own as a
//! defense-in-depth check at startup. They should agree; disagreement is
//! a bug.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use thiserror::Error;

use crate::config::{Config, DeviceCatalogEntry, Effect, Room, Trigger};
use crate::config::catalog::PlugProtocol;
use crate::config::switch_model::{Gesture, SwitchModel};

/// Stable name → resolved room data. Built from the raw `Config::rooms`
/// after validation; the controller indexes everything by room name.
pub type RoomName = String;

/// Friendly name of a switch, light, or motion sensor.
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

    #[error(
        "group name {group_name:?} (room {room:?}) collides with a {device_kind} in the \
         device catalog — both would share the same zigbee2mqtt/<name> MQTT topic"
    )]
    GroupNameDeviceCollision {
        group_name: FriendlyName,
        room: RoomName,
        device_kind: &'static str,
    },

    #[error("room {room:?} has parent {parent:?} which is not a known room")]
    UnknownParent { room: RoomName, parent: RoomName },

    #[error("room {0:?} lists itself as parent")]
    SelfParent(RoomName),

    #[error("parent chain cycle: {chain}")]
    ParentChainCycle { chain: String },

    #[error("room {room:?} references motion sensor {sensor:?} which is not in the device catalog")]
    MotionSensorNotInCatalog {
        room: RoomName,
        sensor: FriendlyName,
    },

    #[error(
        "room {room:?} references motion sensor {sensor:?} but it is a {kind} \
         (expected motion-sensor)"
    )]
    MotionSensorWrongKind {
        room: RoomName,
        sensor: FriendlyName,
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

    #[error("sun-relative schedule expressions require a `location` in the config")]
    MissingLocationForSunExpressions,

    #[error("duplicate binding name {0:?}")]
    DuplicateBindingName(String),

    #[error(
        "binding {binding:?} trigger references device {device:?} which is not in the catalog"
    )]
    BindingTriggerUnknownDevice { binding: String, device: String },

    #[error(
        "binding {binding:?} trigger requires a switch device \
         but {device:?} is a {actual_kind}"
    )]
    BindingTriggerWrongDeviceKind {
        binding: String,
        device: String,
        actual_kind: &'static str,
    },

    #[error(
        "binding {binding:?} references button {button:?} on device {device:?} \
         (model {model:?}) which does not have that button"
    )]
    BindingButtonNotInModel {
        binding: String,
        device: String,
        model: String,
        button: String,
    },

    #[error(
        "binding {binding:?} references room {room:?} which is not defined"
    )]
    BindingRoomNotFound { binding: String, room: String },

    #[error(
        "binding {binding:?} effect targets device {device:?} which is not in the catalog"
    )]
    BindingEffectUnknownDevice { binding: String, device: String },

    #[error(
        "binding {binding:?} effect targets device {device:?} which is a {kind} \
         (only plugs can be binding targets)"
    )]
    BindingEffectNotPlug { binding: String, device: String, kind: &'static str },

    #[error(
        "binding {binding:?} uses power_below trigger on device {device:?} which \
         lacks the \"power\" capability (variant: {variant})"
    )]
    BindingPowerBelowWithoutCapability {
        binding: String,
        device: String,
        variant: String,
    },

    #[error(
        "binding {binding:?} has power_below trigger on device {trigger_device:?} but \
         effect targets device {effect_target:?} — kill-switch rules must target the \
         same plug they monitor"
    )]
    PowerBelowCrossTarget {
        binding: String,
        trigger_device: String,
        effect_target: String,
    },

    #[error(
        "room {room:?} has negative off_transition_seconds: {value}"
    )]
    NegativeTransition { room: RoomName, value: f64 },

    #[error(
        "defaults.cycle_window_seconds is negative: {0}"
    )]
    NegativeCycleWindow(f64),

    #[error(
        "defaults.double_tap_suppression_seconds is negative: {0}"
    )]
    NegativeDoubleTapSuppression(f64),

    #[error(
        "binding {binding:?} has confirm_off_seconds negative: {value}"
    )]
    NegativeConfirmOffWindow { binding: String, value: f64 },

    #[error(
        "binding {binding:?} has At trigger with invalid time: {time}"
    )]
    InvalidAtTime { binding: String, time: String },

    #[error(
        "plug {device:?} has protocol zwave but no node_id"
    )]
    ZwavePlugMissingNodeId {
        device: FriendlyName,
    },

    #[error(
        "duplicate zwave node_id {node_id} (used by plugs {first:?} and {second:?})"
    )]
    DuplicateZwaveNodeId {
        node_id: u16,
        first: FriendlyName,
        second: FriendlyName,
    },

    #[error(
        "switch device {device:?} references unknown model {model:?}"
    )]
    UnknownSwitchModel {
        device: FriendlyName,
        model: String,
    },

    #[error("heating config error: {0}")]
    HeatingError(#[from] crate::config::heating::HeatingConfigError),
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

    /// Motion sensors bound to this room. Empty if none.
    pub bound_motion: Vec<MotionBinding>,
}

impl ResolvedRoom {
    /// Quick check used by the runtime to gate motion-cooldown logic.
    pub fn has_motion_sensor(&self) -> bool {
        !self.bound_motion.is_empty()
    }
}

/// One resolved binding, ready for runtime dispatch.
#[derive(Debug, Clone)]
pub struct ResolvedBinding {
    pub name: String,
    pub trigger: Trigger,
    pub effect: Effect,
}

/// The validated topology. Owned as `Arc<Topology>` by the daemon.
#[derive(Debug)]
pub struct Topology {
    rooms: BTreeMap<RoomName, ResolvedRoom>,
    /// group friendly_name → room name. The controller uses this to
    /// route incoming `zigbee2mqtt/<group>` state events to the right
    /// room.
    by_group_name: BTreeMap<FriendlyName, RoomName>,

    /// Motion sensor friendly_name → list of rooms it drives. Same shape
    /// as the old switch_index; production has each sensor in one room.
    motion_index: BTreeMap<FriendlyName, Vec<RoomName>>,

    /// Transitive descendants per room. Filtered to descendants that
    /// have rules — rule-less rooms have no per-zone state, so propagating
    /// "physically_on" to them would be pointless.
    descendants_by_room: BTreeMap<RoomName, Vec<RoomName>>,

    /// Validated bindings, in config order.
    bindings: Vec<ResolvedBinding>,

    /// (device, button, gesture) → binding indexes. The runtime dispatches
    /// each button event by looking up all matching bindings and executing
    /// them in order.
    button_binding_index: BTreeMap<(String, String, Gesture), Vec<usize>>,

    /// PowerBelow binding indexes, keyed by plug device name.
    power_below_index: BTreeMap<FriendlyName, Vec<usize>>,

    /// All switch device names from catalog. Used for MQTT subscriptions.
    switch_names: BTreeSet<FriendlyName>,

    /// (device, button) pairs that have at least one soft_double_tap
    /// binding. The runtime uses this to activate the software
    /// double-tap detection window.
    soft_double_tap_buttons: BTreeSet<(String, String)>,

    /// (device, button) pairs from switch models that have both press and
    /// double_tap gestures mapped. The runtime uses this to activate the
    /// hardware double-tap suppression guard.
    hw_double_tap_buttons: BTreeSet<(String, String)>,

    /// Rooms that have at least one binding targeting them. Used by
    /// `ResolvedRoom::has_rules()` (via the topology) to determine
    /// whether a room participates in descendant propagation.
    rooms_with_bindings: BTreeSet<RoomName>,

    /// Device name → switch model name mapping.
    device_models: BTreeMap<String, String>,

    /// Switch model descriptors, keyed by model name. Stored so we can
    /// resolve raw z2m action strings to (button, gesture) pairs at
    /// parse time without needing the full Config.
    switch_models: BTreeMap<String, SwitchModel>,

    /// All plug friendly_names from the device catalog.
    plug_names: BTreeSet<FriendlyName>,

    /// Zigbee plug friendly_names (subset of plug_names).
    zigbee_plug_names: BTreeSet<FriendlyName>,

    /// Z-Wave plug friendly_names (subset of plug_names).
    zwave_plug_names: BTreeSet<FriendlyName>,

    /// Per-plug protocol, keyed by friendly_name.
    plug_protocols: BTreeMap<FriendlyName, PlugProtocol>,

    /// Z-Wave node_id → plug friendly_name mapping. Used by the
    /// provisioner to map discovered nodes to their desired names.
    zwave_node_id_to_name: BTreeMap<u16, FriendlyName>,

    /// TRV device friendly_names from the device catalog.
    trv_names: BTreeSet<FriendlyName>,

    /// Wall thermostat device friendly_names from the device catalog.
    wall_thermostat_names: BTreeSet<FriendlyName>,

    /// Validated heating config (if present). Stored for the controller.
    heating_config: Option<crate::config::HeatingConfig>,
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

        // 2b. MQTT namespace safety: group names must not collide with
        //     any device catalog name. Both share the bare
        //     `zigbee2mqtt/<name>` topic namespace, and a collision would
        //     cause parse_event to misroute messages.
        for room in &config.rooms {
            if let Some(entry) = config.devices.get(&room.group_name) {
                return Err(TopologyError::GroupNameDeviceCollision {
                    group_name: room.group_name.clone(),
                    room: room.name.clone(),
                    device_kind: kind_label(entry),
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
        let mut needs_location = false;
        for room in &config.rooms {
            room.scenes
                .validate()
                .map_err(|source| TopologyError::InvalidSceneSchedule {
                    room: room.name.clone(),
                    source,
                })?;
            if room.scenes.uses_sun_expressions() {
                needs_location = true;
            }
        }
        // Location check deferred until after bindings (At triggers may also need it).

        // 4b. Duration and defaults validation.
        if config.defaults.cycle_window_seconds < 0.0 {
            return Err(TopologyError::NegativeCycleWindow(
                config.defaults.cycle_window_seconds,
            ));
        }
        if config.defaults.double_tap_suppression_seconds < 0.0 {
            return Err(TopologyError::NegativeDoubleTapSuppression(
                config.defaults.double_tap_suppression_seconds,
            ));
        }
        for room in &config.rooms {
            if room.off_transition_seconds < 0.0 {
                return Err(TopologyError::NegativeTransition {
                    room: room.name.clone(),
                    value: room.off_transition_seconds,
                });
            }
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

        // 6. Motion sensor bindings from room.motion_sensors.
        let mut motion_index: BTreeMap<FriendlyName, Vec<RoomName>> = BTreeMap::new();
        let mut bound_motion_per_room: BTreeMap<RoomName, Vec<MotionBinding>> = BTreeMap::new();

        for room in &config.rooms {
            for sensor_name in &room.motion_sensors {
                let catalog = config.devices.get(sensor_name).ok_or_else(|| {
                    TopologyError::MotionSensorNotInCatalog {
                        room: room.name.clone(),
                        sensor: sensor_name.clone(),
                    }
                })?;
                match catalog {
                    DeviceCatalogEntry::MotionSensor {
                        occupancy_timeout_seconds,
                        max_illuminance,
                        ..
                    } => {
                        bound_motion_per_room
                            .entry(room.name.clone())
                            .or_default()
                            .push(MotionBinding {
                                sensor: sensor_name.clone(),
                                room: room.name.clone(),
                                occupancy_timeout_seconds: *occupancy_timeout_seconds,
                                max_illuminance: *max_illuminance,
                            });
                        motion_index
                            .entry(sensor_name.clone())
                            .or_default()
                            .push(room.name.clone());
                    }
                    other => {
                        return Err(TopologyError::MotionSensorWrongKind {
                            room: room.name.clone(),
                            sensor: sensor_name.clone(),
                            kind: kind_label(other),
                        });
                    }
                }
            }
        }

        // 7. Validate bindings and build dispatch indexes.
        let mut binding_names: BTreeSet<String> = BTreeSet::new();
        let mut resolved_bindings: Vec<ResolvedBinding> = Vec::new();
        let mut button_binding_index: BTreeMap<(String, String, Gesture), Vec<usize>> = BTreeMap::new();
        let mut power_below_index: BTreeMap<FriendlyName, Vec<usize>> = BTreeMap::new();
        let mut soft_double_tap_buttons: BTreeSet<(String, String)> = BTreeSet::new();
        let mut rooms_with_bindings: BTreeSet<RoomName> = BTreeSet::new();

        for rule in &config.bindings {
            // Name uniqueness.
            if !binding_names.insert(rule.name.clone()) {
                return Err(TopologyError::DuplicateBindingName(rule.name.clone()));
            }

            // Validate trigger device (if the trigger references one).
            let trigger_entry = if let Some(trigger_device) = rule.trigger.device() {
                let entry = config.devices.get(trigger_device).ok_or_else(|| {
                    TopologyError::BindingTriggerUnknownDevice {
                        binding: rule.name.clone(),
                        device: trigger_device.to_string(),
                    }
                })?;
                Some(entry)
            } else {
                None
            };

            match &rule.trigger {
                Trigger::Button { device, button, gesture } => {
                    let trigger_entry = trigger_entry.unwrap();
                    if !trigger_entry.is_switch() {
                        return Err(TopologyError::BindingTriggerWrongDeviceKind {
                            binding: rule.name.clone(),
                            device: device.clone(),
                            actual_kind: kind_label(trigger_entry),
                        });
                    }
                    // Validate button name exists in the device's model.
                    if let Some(model_name) = trigger_entry.switch_model() {
                        if let Some(model) = config.switch_models.get(model_name) {
                            if !model.buttons.contains(button) {
                                return Err(TopologyError::BindingButtonNotInModel {
                                    binding: rule.name.clone(),
                                    device: device.clone(),
                                    model: model_name.to_string(),
                                    button: button.clone(),
                                });
                            }
                        }
                    }
                    let idx = resolved_bindings.len();
                    button_binding_index
                        .entry((device.clone(), button.clone(), *gesture))
                        .or_default()
                        .push(idx);
                    if *gesture == Gesture::SoftDoubleTap {
                        soft_double_tap_buttons.insert((device.clone(), button.clone()));
                    }
                }
                Trigger::PowerBelow { device, .. } => {
                    let trigger_entry = trigger_entry.unwrap();
                    if !trigger_entry.is_plug() {
                        return Err(TopologyError::BindingTriggerWrongDeviceKind {
                            binding: rule.name.clone(),
                            device: device.clone(),
                            actual_kind: kind_label(trigger_entry),
                        });
                    }
                    if !trigger_entry.has_capability("power") {
                        let variant = match trigger_entry {
                            DeviceCatalogEntry::Plug { variant, .. } => variant.clone(),
                            _ => "unknown".into(),
                        };
                        return Err(TopologyError::BindingPowerBelowWithoutCapability {
                            binding: rule.name.clone(),
                            device: device.clone(),
                            variant,
                        });
                    }
                    // Kill-switch rules must target the same plug they
                    // monitor. Cross-target rules would mutate the wrong
                    // runtime state and are not covered by the TLA model.
                    if let Some(effect_target) = rule.effect.target() {
                        if effect_target != device {
                            return Err(TopologyError::PowerBelowCrossTarget {
                                binding: rule.name.clone(),
                                trigger_device: device.clone(),
                                effect_target: effect_target.to_string(),
                            });
                        }
                    }
                    let idx = resolved_bindings.len();
                    power_below_index
                        .entry(device.clone())
                        .or_default()
                        .push(idx);
                }
                Trigger::At { time } => {
                    if let crate::config::time_expr::TimeExpr::Fixed { minute_of_day } = time {
                        // Reject >= 1440 (24:00): the clock's local_hour is
                        // 0-23 so minute 1440 would resolve to hour=24 and
                        // never match, creating a silently dead rule.
                        if *minute_of_day >= 1440 {
                            return Err(TopologyError::InvalidAtTime {
                                binding: rule.name.clone(),
                                time: time.to_string(),
                            });
                        }
                    }
                    if time.uses_sun() {
                        needs_location = true;
                    }
                }
            }

            // Validate room-targeting effects: the room must exist.
            if let Some(room_name) = rule.effect.room() {
                if !rooms_by_name.contains_key(room_name) {
                    return Err(TopologyError::BindingRoomNotFound {
                        binding: rule.name.clone(),
                        room: room_name.to_string(),
                    });
                }
                rooms_with_bindings.insert(room_name.to_string());
            }

            // Validate device-targeting effects: target must be a plug.
            if let Some(effect_target) = rule.effect.target() {
                let effect_entry = config.devices.get(effect_target).ok_or_else(|| {
                    TopologyError::BindingEffectUnknownDevice {
                        binding: rule.name.clone(),
                        device: effect_target.to_string(),
                    }
                })?;
                if !effect_entry.is_plug() {
                    return Err(TopologyError::BindingEffectNotPlug {
                        binding: rule.name.clone(),
                        device: effect_target.to_string(),
                        kind: kind_label(effect_entry),
                    });
                }
            }

            // Validate confirm_off_seconds if present.
            if let Some(secs) = rule.effect.confirm_off_seconds() {
                if secs < 0.0 {
                    return Err(TopologyError::NegativeConfirmOffWindow {
                        binding: rule.name.clone(),
                        value: secs,
                    });
                }
            }

            resolved_bindings.push(ResolvedBinding {
                name: rule.name.clone(),
                trigger: rule.trigger.clone(),
                effect: rule.effect.clone(),
            });
        }

        // 7b. Build resolved rooms now that all per-room data has been
        //     validated and split.
        let mut rooms: BTreeMap<RoomName, ResolvedRoom> = BTreeMap::new();
        for room in &config.rooms {
            let bound_motion = bound_motion_per_room
                .remove(&room.name)
                .unwrap_or_default();
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
                    bound_motion,
                },
            );
        }

        // 8. group_name → room_name index.
        let by_group_name = rooms
            .values()
            .map(|r| (r.group_name.clone(), r.name.clone()))
            .collect();

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
                        let has_rules = !room.bound_motion.is_empty()
                            || rooms_with_bindings.contains(&curr);
                        if has_rules {
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

        // 10. Collect all plug names and protocol metadata from the catalog.
        let mut plug_names: BTreeSet<FriendlyName> = BTreeSet::new();
        let mut zigbee_plug_names: BTreeSet<FriendlyName> = BTreeSet::new();
        let mut zwave_plug_names: BTreeSet<FriendlyName> = BTreeSet::new();
        let mut plug_protocols: BTreeMap<FriendlyName, PlugProtocol> = BTreeMap::new();
        let mut zwave_node_id_to_name: BTreeMap<u16, FriendlyName> = BTreeMap::new();

        for (name, entry) in &config.devices {
            if !entry.is_plug() {
                continue;
            }
            plug_names.insert(name.clone());
            let protocol = entry.plug_protocol().unwrap_or_default();
            plug_protocols.insert(name.clone(), protocol);

            match protocol {
                PlugProtocol::Zwave => {
                    let node_id = entry.zwave_node_id().ok_or_else(|| {
                        TopologyError::ZwavePlugMissingNodeId { device: name.clone() }
                    })?;
                    if let Some(existing) = zwave_node_id_to_name.get(&node_id) {
                        return Err(TopologyError::DuplicateZwaveNodeId {
                            node_id,
                            first: existing.clone(),
                            second: name.clone(),
                        });
                    }
                    zwave_node_id_to_name.insert(node_id, name.clone());
                    zwave_plug_names.insert(name.clone());
                }
                PlugProtocol::Zigbee => {
                    zigbee_plug_names.insert(name.clone());
                }
            }
        }

        // Every plug must be classified as exactly one protocol.
        debug_assert_eq!(
            plug_names.len(),
            zigbee_plug_names.len() + zwave_plug_names.len(),
            "every plug must be either zigbee or zwave"
        );

        // 10b. Collect TRV and wall thermostat names from the catalog.
        let mut trv_names: BTreeSet<FriendlyName> = BTreeSet::new();
        let mut wall_thermostat_names: BTreeSet<FriendlyName> = BTreeSet::new();
        for (name, entry) in &config.devices {
            if entry.is_trv() {
                trv_names.insert(name.clone());
            }
            if entry.is_wall_thermostat() {
                wall_thermostat_names.insert(name.clone());
            }
        }

        // 10c. Validate heating config if present.
        let heating_config = if let Some(ref heating) = config.heating {
            use crate::config::heating::HeatingConfigError;
            // Validate schedules.
            heating
                .validate_schedules()
                .map_err(|e| TopologyError::HeatingError(e))?;

            // Validate zone references.
            let mut trv_to_zone: BTreeMap<String, String> = BTreeMap::new();
            let mut relay_to_zone: BTreeMap<String, String> = BTreeMap::new();
            let mut zone_names: BTreeSet<String> = BTreeSet::new();

            for zone in &heating.zones {
                if !zone_names.insert(zone.name.clone()) {
                    return Err(TopologyError::HeatingError(
                        HeatingConfigError::DuplicateZoneName {
                            zone: zone.name.clone(),
                        },
                    ));
                }
                if zone.trvs.is_empty() {
                    return Err(TopologyError::HeatingError(
                        HeatingConfigError::ZoneEmpty {
                            zone: zone.name.clone(),
                        },
                    ));
                }
                if !wall_thermostat_names.contains(&zone.relay) {
                    return Err(TopologyError::HeatingError(
                        HeatingConfigError::RelayNotWallThermostat {
                            zone: zone.name.clone(),
                            relay: zone.relay.clone(),
                        },
                    ));
                }
                // Validate the wall thermostat has the required options
                // for safe relay control.
                if let Some(entry) = config.devices.get(&zone.relay) {
                    let opts = entry.options();
                    // heater_type = manual_control is a hard requirement:
                    // without it the wall thermostat runs its own climate
                    // algorithm and ignores our ON/OFF relay commands.
                    let has_manual_control = opts
                        .get("heater_type")
                        .and_then(|v| v.as_str())
                        .is_some_and(|v| v == "manual_control");
                    if !has_manual_control {
                        return Err(TopologyError::HeatingError(
                            HeatingConfigError::RelayMissingManualControl {
                                zone: zone.name.clone(),
                                relay: zone.relay.clone(),
                            },
                        ));
                    }
                    // operating_mode = manual is a hard requirement:
                    // without it the wall thermostat's internal schedule
                    // overrides our relay commands.
                    let has_manual_mode = opts
                        .get("operating_mode")
                        .and_then(|v| v.as_str())
                        .is_some_and(|v| v == "manual");
                    if !has_manual_mode {
                        return Err(TopologyError::HeatingError(
                            HeatingConfigError::DeviceMissingManualMode {
                                zone: zone.name.clone(),
                                device: zone.relay.clone(),
                                device_kind: "relay",
                            },
                        ));
                    }
                    crate::config::heating::validate_wall_thermostat_options(
                        &zone.relay, opts,
                    ).map_err(TopologyError::HeatingError)?;
                }
                if let Some(other_zone) = relay_to_zone.insert(zone.relay.clone(), zone.name.clone()) {
                    return Err(TopologyError::HeatingError(
                        HeatingConfigError::DuplicateRelay {
                            zone: zone.name.clone(),
                            relay: zone.relay.clone(),
                            other_zone,
                        },
                    ));
                }
                for zt in &zone.trvs {
                    if !trv_names.contains(&zt.device) {
                        return Err(TopologyError::HeatingError(
                            HeatingConfigError::TrvNotInCatalog {
                                zone: zone.name.clone(),
                                trv: zt.device.clone(),
                            },
                        ));
                    }
                    // Validate TRV options.
                    if let Some(entry) = config.devices.get(&zt.device) {
                        let opts = entry.options();
                        let has_manual = opts
                            .get("operating_mode")
                            .and_then(|v| v.as_str())
                            .is_some_and(|v| v == "manual");
                        if !has_manual {
                            return Err(TopologyError::HeatingError(
                                HeatingConfigError::DeviceMissingManualMode {
                                    zone: zone.name.clone(),
                                    device: zt.device.clone(),
                                    device_kind: "TRV",
                                },
                            ));
                        }
                        crate::config::heating::validate_trv_options(&zt.device, opts)
                            .map_err(TopologyError::HeatingError)?;
                    }
                    if !heating.schedules.contains_key(&zt.schedule) {
                        return Err(TopologyError::HeatingError(
                            HeatingConfigError::UnknownSchedule {
                                zone: zone.name.clone(),
                                trv: zt.device.clone(),
                                schedule: zt.schedule.clone(),
                            },
                        ));
                    }
                    if let Some(other_zone) =
                        trv_to_zone.insert(zt.device.clone(), zone.name.clone())
                    {
                        return Err(TopologyError::HeatingError(
                            HeatingConfigError::TrvInMultipleZones {
                                trv: zt.device.clone(),
                                zone_a: other_zone,
                                zone_b: zone.name.clone(),
                            },
                        ));
                    }
                }
            }

            // Validate pressure groups.
            let mut trv_to_group: BTreeMap<String, String> = BTreeMap::new();
            for group in &heating.pressure_groups {
                if group.trvs.len() < 2 {
                    return Err(TopologyError::HeatingError(
                        HeatingConfigError::PressureGroupTooSmall {
                            group: group.name.clone(),
                        },
                    ));
                }
                let mut group_zone: Option<String> = None;
                for trv_name in &group.trvs {
                    let zone_name = trv_to_zone.get(trv_name).ok_or_else(|| {
                        TopologyError::HeatingError(
                            HeatingConfigError::PressureGroupTrvNotInZone {
                                group: group.name.clone(),
                                trv: trv_name.clone(),
                            },
                        )
                    })?;
                    match &group_zone {
                        None => group_zone = Some(zone_name.clone()),
                        Some(first_zone) if first_zone != zone_name => {
                            return Err(TopologyError::HeatingError(
                                HeatingConfigError::PressureGroupMultipleZones {
                                    group: group.name.clone(),
                                    zone_a: first_zone.clone(),
                                    zone_b: zone_name.clone(),
                                },
                            ));
                        }
                        Some(_) => {}
                    }
                    if let Some(other_group) =
                        trv_to_group.insert(trv_name.clone(), group.name.clone())
                    {
                        return Err(TopologyError::HeatingError(
                            HeatingConfigError::TrvInMultiplePressureGroups {
                                trv: trv_name.clone(),
                                group_a: other_group,
                                group_b: group.name.clone(),
                            },
                        ));
                    }
                }
            }

            Some(heating.clone())
        } else {
            None
        };

        // 11. Build switch_names, device_models, and hw_double_tap_buttons
        //     from the device catalog.
        let mut switch_names: BTreeSet<FriendlyName> = BTreeSet::new();
        let mut device_models: BTreeMap<String, String> = BTreeMap::new();
        let mut hw_double_tap_buttons: BTreeSet<(String, String)> = BTreeSet::new();

        for (name, entry) in &config.devices {
            if let DeviceCatalogEntry::Switch { model, .. } = entry {
                switch_names.insert(name.clone());
                device_models.insert(name.clone(), model.clone());

                // Validate that the model exists in switch_models.
                let switch_model = config.switch_models.get(model).ok_or_else(|| {
                    TopologyError::UnknownSwitchModel {
                        device: name.clone(),
                        model: model.clone(),
                    }
                })?;

                // Register per-button hardware double-tap suppression.
                // Only buttons that have both press AND double_tap gestures
                // mapped in the model get suppression — not all buttons on
                // a model that happens to have double-tap somewhere.
                for button in &switch_model.buttons {
                    let has_press = switch_model.z2m_action_map.values().any(|m| {
                        m.button == *button && m.gesture == Gesture::Press
                    });
                    let has_double = switch_model.z2m_action_map.values().any(|m| {
                        m.button == *button && m.gesture == Gesture::DoubleTap
                    });
                    if has_press && has_double {
                        hw_double_tap_buttons.insert((name.clone(), button.clone()));
                    }
                }
            }
        }

        // Location is required if any schedule slot or At trigger uses sun expressions.
        if needs_location && config.location.is_none() {
            return Err(TopologyError::MissingLocationForSunExpressions);
        }

        Ok(Self {
            rooms,
            by_group_name,
            motion_index,
            descendants_by_room,
            bindings: resolved_bindings,
            button_binding_index,
            power_below_index,
            switch_names,
            soft_double_tap_buttons,
            hw_double_tap_buttons,
            rooms_with_bindings,
            device_models,
            switch_models: config.switch_models.clone(),
            plug_names,
            zigbee_plug_names,
            zwave_plug_names,
            plug_protocols,
            zwave_node_id_to_name,
            trv_names,
            wall_thermostat_names,
            heating_config,
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

    /// All switch device names from the catalog. Used for MQTT
    /// subscriptions to action topics.
    pub fn all_switch_device_names(&self) -> &BTreeSet<FriendlyName> {
        &self.switch_names
    }

    /// All distinct motion sensor friendly names.
    pub fn all_motion_sensor_names(&self) -> BTreeSet<&str> {
        self.motion_index.keys().map(String::as_str).collect()
    }

    /// All resolved bindings.
    pub fn bindings(&self) -> &[ResolvedBinding] {
        &self.bindings
    }

    /// Binding indexes triggered by a (device, button, gesture) triple.
    pub fn bindings_for_button(&self, device: &str, button: &str, gesture: Gesture) -> &[usize] {
        self.button_binding_index
            .get(&(device.to_string(), button.to_string(), gesture))
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// Binding indexes with PowerBelow triggers for a plug device.
    pub fn bindings_for_power_below(&self, plug: &str) -> &[usize] {
        self.power_below_index
            .get(plug)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// True if this (device, button) pair has at least one soft_double_tap
    /// binding. Used by the runtime to activate the software double-tap
    /// detection window.
    pub fn is_soft_double_tap_button(&self, device: &str, button: &str) -> bool {
        self.soft_double_tap_buttons.contains(&(device.to_string(), button.to_string()))
    }

    /// True if this (device, button) pair comes from a model with hardware
    /// double-tap support. Used by the runtime to activate the double-tap
    /// suppression guard.
    pub fn is_hw_double_tap_button(&self, device: &str, button: &str) -> bool {
        self.hw_double_tap_buttons.contains(&(device.to_string(), button.to_string()))
    }

    /// The switch model name for a device, if it's a switch.
    pub fn switch_model_for(&self, device: &str) -> Option<&str> {
        self.device_models.get(device).map(String::as_str)
    }

    /// Resolve a raw z2m action string for a switch device into a
    /// semantic `(button, gesture)` pair. Returns `None` if the device
    /// is not a known switch, has no model, or the action string is
    /// unrecognized.
    pub fn resolve_button_event(&self, device: &str, z2m_action: &str) -> Option<(String, Gesture)> {
        let model_name = self.device_models.get(device)?;
        let model = self.switch_models.get(model_name)?;
        let mapping = model.resolve(z2m_action)?;
        Some((mapping.button.clone(), mapping.gesture))
    }

    /// True if the given room has runtime rules (bindings or motion sensors).
    pub fn room_has_rules(&self, room_name: &str) -> bool {
        let has_motion = self.rooms
            .get(room_name)
            .map(|r| !r.bound_motion.is_empty())
            .unwrap_or(false);
        has_motion || self.rooms_with_bindings.contains(room_name)
    }

    /// All plug device friendly names from the catalog.
    pub fn all_plug_names(&self) -> &BTreeSet<FriendlyName> {
        &self.plug_names
    }

    /// True if this device name is a known plug (any protocol).
    pub fn is_plug(&self, device: &str) -> bool {
        self.plug_names.contains(device)
    }

    /// True if this device is a Z-Wave plug.
    pub fn is_zwave_plug(&self, device: &str) -> bool {
        self.zwave_plug_names.contains(device)
    }

    /// Zigbee plug friendly_names.
    pub fn zigbee_plug_names(&self) -> &BTreeSet<FriendlyName> {
        &self.zigbee_plug_names
    }

    /// Z-Wave plug friendly_names.
    pub fn zwave_plug_names(&self) -> &BTreeSet<FriendlyName> {
        &self.zwave_plug_names
    }

    /// The protocol for a plug device. Returns `None` if the device
    /// is not a plug.
    pub fn plug_protocol(&self, device: &str) -> Option<PlugProtocol> {
        self.plug_protocols.get(device).copied()
    }

    /// Z-Wave node_id → plug name mapping. Used by the provisioner.
    pub fn zwave_node_id_to_name(&self) -> &BTreeMap<u16, FriendlyName> {
        &self.zwave_node_id_to_name
    }

    /// All TRV device friendly_names.
    pub fn all_trv_names(&self) -> &BTreeSet<FriendlyName> {
        &self.trv_names
    }

    /// True if `device` is a TRV.
    pub fn is_trv(&self, device: &str) -> bool {
        self.trv_names.contains(device)
    }

    /// All wall thermostat device friendly_names.
    pub fn all_wall_thermostat_names(&self) -> &BTreeSet<FriendlyName> {
        &self.wall_thermostat_names
    }

    /// True if `device` is a wall thermostat.
    pub fn is_wall_thermostat(&self, device: &str) -> bool {
        self.wall_thermostat_names.contains(device)
    }

    /// The validated heating config, if present.
    pub fn heating_config(&self) -> Option<&crate::config::HeatingConfig> {
        self.heating_config.as_ref()
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
        DeviceCatalogEntry::Switch { .. } => "switch",
        DeviceCatalogEntry::MotionSensor { .. } => "motion-sensor",
        DeviceCatalogEntry::Trv(_) => "trv",
        DeviceCatalogEntry::WallThermostat(_) => "wall-thermostat",
        DeviceCatalogEntry::Plug { .. } => "plug",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Binding, CommonFields, Defaults, DeviceCatalogEntry, Effect, Room, Trigger};
    use crate::config::scenes::{Scene, SceneSchedule, Slot};
    use crate::config::switch_model::{ActionMapping, Gesture, SwitchModel};
    use std::collections::BTreeMap;

    fn light(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Light(CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::new(),
        })
    }

    fn switch_dev(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Switch {
            common: CommonFields {
                ieee_address: ieee.into(),
                description: None,
                options: BTreeMap::new(),
            },
            model: "test-dimmer".into(),
        }
    }

    fn switch_dev_model(ieee: &str, model: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Switch {
            common: CommonFields {
                ieee_address: ieee.into(),
                description: None,
                options: BTreeMap::new(),
            },
            model: model.into(),
        }
    }

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
                    from: crate::config::TimeExpr::Fixed { minute_of_day: 0 },
                    to: crate::config::TimeExpr::Fixed { minute_of_day: 1440 },
                    scene_ids: vec![1],
                },
            )]),
        }
    }

    fn room(
        name: &str,
        id: u8,
        members: Vec<&str>,
        motion_sensors: Vec<&str>,
        parent: Option<&str>,
    ) -> Room {
        Room {
            name: name.into(),
            group_name: format!("hue-lz-{name}"),
            id,
            members: members.into_iter().map(String::from).collect(),
            parent: parent.map(String::from),
            motion_sensors: motion_sensors.into_iter().map(String::from).collect(),
            scenes: day_scenes(),
            off_transition_seconds: 0.8,
            motion_off_cooldown_seconds: 0,
        }
    }

    fn room_with_group_name(
        name: &str,
        id: u8,
        group_name: &str,
        members: Vec<&str>,
        parent: Option<&str>,
    ) -> Room {
        Room {
            name: name.into(),
            group_name: group_name.into(),
            id,
            members: members.into_iter().map(String::from).collect(),
            parent: parent.map(String::from),
            motion_sensors: vec![],
            scenes: day_scenes(),
            off_transition_seconds: 0.8,
            motion_off_cooldown_seconds: 0,
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
            protocol: PlugProtocol::default(),
            node_id: None,
        }
    }

    fn zwave_plug_dev(node_id: u16, variant: &str, caps: &[&str]) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Plug {
            common: CommonFields {
                ieee_address: format!("zwave:{node_id}"),
                description: None,
                options: BTreeMap::new(),
            },
            variant: variant.into(),
            capabilities: caps.iter().map(|s| s.to_string()).collect(),
            protocol: PlugProtocol::Zwave,
            node_id: Some(node_id),
        }
    }

    /// Minimal switch model with on/off/up/down buttons, press-only gestures.
    fn test_dimmer_model() -> SwitchModel {
        SwitchModel {
            buttons: vec!["on".into(), "off".into(), "up".into(), "down".into()],
            z2m_action_map: BTreeMap::from([
                ("on_press_release".into(), ActionMapping { button: "on".into(), gesture: Gesture::Press }),
                ("off_press_release".into(), ActionMapping { button: "off".into(), gesture: Gesture::Press }),
                ("up_press_release".into(), ActionMapping { button: "up".into(), gesture: Gesture::Press }),
                ("down_press_release".into(), ActionMapping { button: "down".into(), gesture: Gesture::Press }),
            ]),
        }
    }

    /// Model with hardware double-tap (Sonoff-style).
    fn test_hw_double_tap_model() -> SwitchModel {
        SwitchModel {
            buttons: vec!["1".into(), "2".into()],
            z2m_action_map: BTreeMap::from([
                ("single_button_1".into(), ActionMapping { button: "1".into(), gesture: Gesture::Press }),
                ("single_button_2".into(), ActionMapping { button: "2".into(), gesture: Gesture::Press }),
                ("double_button_1".into(), ActionMapping { button: "1".into(), gesture: Gesture::DoubleTap }),
                ("double_button_2".into(), ActionMapping { button: "2".into(), gesture: Gesture::DoubleTap }),
            ]),
        }
    }

    /// Minimal tap model with numbered buttons.
    fn test_tap_model() -> SwitchModel {
        SwitchModel {
            buttons: vec!["1".into(), "2".into(), "3".into(), "4".into()],
            z2m_action_map: BTreeMap::from([
                ("1_single".into(), ActionMapping { button: "1".into(), gesture: Gesture::Press }),
                ("2_single".into(), ActionMapping { button: "2".into(), gesture: Gesture::Press }),
                ("3_single".into(), ActionMapping { button: "3".into(), gesture: Gesture::Press }),
                ("4_single".into(), ActionMapping { button: "4".into(), gesture: Gesture::Press }),
            ]),
        }
    }

    fn default_switch_models() -> BTreeMap<String, SwitchModel> {
        BTreeMap::from([
            ("test-dimmer".into(), test_dimmer_model()),
            ("test-tap".into(), test_tap_model()),
            ("test-hw-dbl".into(), test_hw_double_tap_model()),
        ])
    }

    fn config(devices: Vec<(&str, DeviceCatalogEntry)>, rooms: Vec<Room>) -> Config {
        config_with_bindings(devices, rooms, vec![])
    }

    fn config_with_bindings(
        devices: Vec<(&str, DeviceCatalogEntry)>,
        rooms: Vec<Room>,
        bindings: Vec<Binding>,
    ) -> Config {
        let devices = devices
            .into_iter()
            .map(|(n, e)| (n.to_string(), e))
            .collect();
        Config {
            name_by_address: BTreeMap::new(),
            devices,
            switch_models: default_switch_models(),
            rooms,
            bindings,
            defaults: Default::default(),
            heating: None,
            location: None,
        }
    }

    #[test]
    fn empty_config_builds() {
        let cfg = config(vec![], vec![]);
        let topo = Topology::build(&cfg).unwrap();
        assert!(topo.rooms().next().is_none());
    }

    #[test]
    fn room_with_switch_binding_builds_and_indexes() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-s-a", switch_dev("0x1")),
            ],
            vec![room("study", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![Binding {
                name: "study-on".into(),
                trigger: Trigger::Button {
                    device: "hue-s-a".into(),
                    button: "on".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::SceneCycle { room: "study".into() },
            }],
        );
        let topo = Topology::build(&cfg).unwrap();
        let r = topo.room_by_name("study").unwrap();
        assert!(r.bound_motion.is_empty());
        assert!(topo.room_has_rules("study"));

        assert_eq!(
            topo.bindings_for_button("hue-s-a", "on", Gesture::Press),
            &[0]
        );
        assert_eq!(topo.room_by_group_name("hue-lz-study").unwrap().name, "study");
    }

    #[test]
    fn motion_sensor_binding_routes_to_room() {
        let cfg = config(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-ms-a", motion("0x3")),
            ],
            vec![room("study", 1, vec!["hue-l-a/11"], vec!["hue-ms-a"], None)],
        );
        let topo = Topology::build(&cfg).unwrap();
        let r = topo.room_by_name("study").unwrap();
        assert!(r.has_motion_sensor());
        assert_eq!(r.bound_motion.len(), 1);
        assert_eq!(r.bound_motion[0].sensor, "hue-ms-a");
        assert_eq!(topo.rooms_for_motion("hue-ms-a"), &["study".to_string()]);
    }

    #[test]
    fn motion_sensor_not_in_catalog_rejected() {
        let cfg = config(
            vec![("hue-l-a", light("0xa"))],
            vec![room("study", 1, vec!["hue-l-a/11"], vec!["hue-ms-ghost"], None)],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::MotionSensorNotInCatalog { .. }));
    }

    #[test]
    fn motion_sensor_wrong_kind_rejected() {
        let cfg = config(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-s-a", switch_dev("0x1")),
            ],
            vec![room("study", 1, vec!["hue-l-a/11"], vec!["hue-s-a"], None)],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::MotionSensorWrongKind { kind: "switch", .. }));
    }

    #[test]
    fn button_binding_routes_to_correct_index() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-l-b", light("0xb")),
                ("hue-ts-foo", switch_dev_model("0x1", "test-tap")),
            ],
            vec![
                room(
                    "kitchen-cooker", 1, vec!["hue-l-a/11"], vec![],
                    Some("kitchen-all"),
                ),
                room(
                    "kitchen-all", 2, vec!["hue-l-a/11", "hue-l-b/11"], vec![],
                    None,
                ),
            ],
            vec![
                Binding {
                    name: "cooker-tap".into(),
                    trigger: Trigger::Button {
                        device: "hue-ts-foo".into(),
                        button: "2".into(),
                        gesture: Gesture::Press,
                    },
                    effect: Effect::SceneToggleCycle { room: "kitchen-cooker".into() },
                },
                Binding {
                    name: "all-tap".into(),
                    trigger: Trigger::Button {
                        device: "hue-ts-foo".into(),
                        button: "1".into(),
                        gesture: Gesture::Press,
                    },
                    effect: Effect::SceneToggleCycle { room: "kitchen-all".into() },
                },
            ],
        );
        let topo = Topology::build(&cfg).unwrap();

        assert_eq!(
            topo.bindings_for_button("hue-ts-foo", "1", Gesture::Press),
            &[1]
        );
        assert_eq!(
            topo.bindings_for_button("hue-ts-foo", "2", Gesture::Press),
            &[0]
        );
        assert!(topo.bindings_for_button("hue-ts-foo", "3", Gesture::Press).is_empty());
    }

    #[test]
    fn duplicate_group_id_rejected() {
        let cfg = config(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-l-b", light("0xb")),
            ],
            vec![
                room("a", 1, vec!["hue-l-a/11"], vec![], None),
                room("b", 1, vec!["hue-l-b/11"], vec![], None),
            ],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::DuplicateGroupId { id: 1, .. }));
    }

    #[test]
    fn duplicate_group_friendly_name_rejected() {
        let cfg = config(
            vec![("hue-l-a", light("0xa"))],
            vec![
                Room {
                    name: "a".into(),
                    group_name: "shared".into(),
                    id: 1,
                    members: vec!["hue-l-a/11".into()],
                    parent: None,
                    motion_sensors: vec![],
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
                    motion_sensors: vec![],
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
    fn group_name_device_collision_rejected() {
        // Group name "z2m-p-foo" collides with a plug in the device catalog.
        let cfg = config(
            vec![
                ("hue-l-a", light("0xa")),
                ("z2m-p-foo", plug_dev("0xf", "sonoff-basic", &["on-off"])),
            ],
            vec![room_with_group_name(
                "a", 1, "z2m-p-foo",
                vec!["hue-l-a/11"], None,
            )],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::GroupNameDeviceCollision { .. }));
    }

    #[test]
    fn unknown_parent_rejected() {
        let cfg = config(
            vec![("hue-l-a", light("0xa"))],
            vec![room("child", 1, vec!["hue-l-a/11"], vec![], Some("ghost"))],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::UnknownParent { .. }));
    }

    #[test]
    fn self_parent_rejected() {
        let cfg = config(
            vec![("hue-l-a", light("0xa"))],
            vec![room("loop", 1, vec!["hue-l-a/11"], vec![], Some("loop"))],
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
            ],
            vec![
                room("a", 1, vec!["hue-l-a/11"], vec![], Some("b")),
                room("b", 2, vec!["hue-l-b/11"], vec![], Some("a")),
            ],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::ParentChainCycle { .. }));
    }

    #[test]
    fn member_referencing_non_light_rejected() {
        let cfg = config(
            vec![("hue-s-a", switch_dev("0x1"))],
            vec![room("a", 1, vec!["hue-s-a/11"], vec![], None)],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::UnknownMemberLight { .. }));
    }

    #[test]
    fn malformed_member_rejected() {
        let cfg = config(
            vec![("hue-l-a", light("0xa"))],
            vec![room("a", 1, vec!["hue-l-a"], vec![], None)],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::MalformedMember { .. }));
    }

    #[test]
    fn binding_toggle_plug_builds_and_indexes() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-ts-foo", switch_dev_model("0x1", "test-tap")),
                ("z2m-p-printer", plug_dev("0xf", "sonoff-power", &["on-off", "power"])),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![Binding {
                name: "printer-toggle".into(),
                trigger: Trigger::Button {
                    device: "hue-ts-foo".into(),
                    button: "3".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-printer".into() },
            }],
        );
        let topo = Topology::build(&cfg).unwrap();
        assert_eq!(topo.bindings().len(), 1);
        assert_eq!(topo.bindings_for_button("hue-ts-foo", "3", Gesture::Press), &[0]);
        assert!(topo.bindings_for_button("hue-ts-foo", "1", Gesture::Press).is_empty());
        assert!(topo.is_plug("z2m-p-printer"));
        assert!(!topo.is_plug("hue-l-a"));
    }

    #[test]
    fn binding_switch_on_off_builds_and_indexes() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-s-office", switch_dev("0x1")),
                ("z2m-p-lamp", plug_dev("0xf", "sonoff-basic", &["on-off"])),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![
                Binding {
                    name: "lamp-on".into(),
                    trigger: Trigger::Button {
                        device: "hue-s-office".into(),
                        button: "on".into(),
                        gesture: Gesture::Press,
                    },
                    effect: Effect::TurnOn { target: "z2m-p-lamp".into() },
                },
                Binding {
                    name: "lamp-off".into(),
                    trigger: Trigger::Button {
                        device: "hue-s-office".into(),
                        button: "off".into(),
                        gesture: Gesture::Press,
                    },
                    effect: Effect::TurnOff { target: "z2m-p-lamp".into() },
                },
            ],
        );
        let topo = Topology::build(&cfg).unwrap();
        assert_eq!(topo.bindings().len(), 2);
        assert_eq!(topo.bindings_for_button("hue-s-office", "on", Gesture::Press), &[0]);
        assert_eq!(topo.bindings_for_button("hue-s-office", "off", Gesture::Press), &[1]);
    }

    #[test]
    fn binding_power_below_builds_and_indexes() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("z2m-p-printer", plug_dev("0xf", "sonoff-power", &["on-off", "power"])),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![Binding {
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
        assert_eq!(topo.bindings_for_power_below("z2m-p-printer"), &[0]);
    }

    #[test]
    fn binding_power_below_without_capability_rejected() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("z2m-p-basic", plug_dev("0xf", "sonoff-basic", &["on-off"])),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![Binding {
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
        assert!(matches!(err, TopologyError::BindingPowerBelowWithoutCapability { .. }));
    }

    #[test]
    fn binding_trigger_wrong_device_kind_rejected() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("z2m-p-printer", plug_dev("0xf", "sonoff-power", &["on-off", "power"])),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![Binding {
                name: "bad".into(),
                trigger: Trigger::Button {
                    device: "hue-l-a".into(),
                    button: "1".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-printer".into() },
            }],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::BindingTriggerWrongDeviceKind { .. }));
    }

    #[test]
    fn binding_button_not_in_model_rejected() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-ts-foo", switch_dev_model("0x1", "test-tap")),
                ("z2m-p-a", plug_dev("0xf", "sonoff-basic", &["on-off"])),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![Binding {
                name: "bad".into(),
                trigger: Trigger::Button {
                    device: "hue-ts-foo".into(),
                    button: "nonexistent".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-a".into() },
            }],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::BindingButtonNotInModel { .. }));
    }

    #[test]
    fn binding_effect_not_plug_rejected() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-ts-foo", switch_dev_model("0x1", "test-tap")),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![Binding {
                name: "bad".into(),
                trigger: Trigger::Button {
                    device: "hue-ts-foo".into(),
                    button: "1".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::Toggle { confirm_off_seconds: None, target: "hue-l-a".into() },
            }],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::BindingEffectNotPlug { .. }));
    }

    #[test]
    fn duplicate_binding_name_rejected() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-ts-foo", switch_dev_model("0x1", "test-tap")),
                ("z2m-p-a", plug_dev("0xf", "sonoff-basic", &["on-off"])),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![
                Binding {
                    name: "dupe".into(),
                    trigger: Trigger::Button {
                        device: "hue-ts-foo".into(),
                        button: "1".into(),
                        gesture: Gesture::Press,
                    },
                    effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-a".into() },
                },
                Binding {
                    name: "dupe".into(),
                    trigger: Trigger::Button {
                        device: "hue-ts-foo".into(),
                        button: "2".into(),
                        gesture: Gesture::Press,
                    },
                    effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-a".into() },
                },
            ],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::DuplicateBindingName(_)));
    }

    #[test]
    fn binding_trigger_unknown_device_rejected() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("z2m-p-a", plug_dev("0xf", "sonoff-basic", &["on-off"])),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![Binding {
                name: "bad".into(),
                trigger: Trigger::Button {
                    device: "ghost".into(),
                    button: "1".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-a".into() },
            }],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::BindingTriggerUnknownDevice { .. }));
    }

    #[test]
    fn binding_effect_unknown_device_rejected() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-ts-foo", switch_dev_model("0x1", "test-tap")),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![Binding {
                name: "bad".into(),
                trigger: Trigger::Button {
                    device: "hue-ts-foo".into(),
                    button: "1".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::Toggle { confirm_off_seconds: None, target: "ghost".into() },
            }],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::BindingEffectUnknownDevice { .. }));
    }

    #[test]
    fn binding_room_not_found_rejected() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-s-a", switch_dev("0x1")),
            ],
            vec![room("study", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![Binding {
                name: "ghost-room".into(),
                trigger: Trigger::Button {
                    device: "hue-s-a".into(),
                    button: "on".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::SceneCycle { room: "nonexistent".into() },
            }],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::BindingRoomNotFound { .. }));
    }

    #[test]
    fn descendants_filter_rule_less_rooms() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-l-b", light("0xb")),
                ("hue-l-c", light("0xc")),
                ("hue-s-cooker", switch_dev("0x1")),
                ("hue-s-all", switch_dev("0x2")),
            ],
            vec![
                room(
                    "kitchen-cooker", 1, vec!["hue-l-a/11"], vec![],
                    Some("kitchen-all"),
                ),
                // Rule-less child: no bindings, no motion sensors.
                room(
                    "kitchen-empty", 2, vec!["hue-l-b/11"], vec![],
                    Some("kitchen-all"),
                ),
                room(
                    "kitchen-all", 3,
                    vec!["hue-l-a/11", "hue-l-b/11", "hue-l-c/11"],
                    vec![], None,
                ),
            ],
            vec![
                Binding {
                    name: "cooker-on".into(),
                    trigger: Trigger::Button {
                        device: "hue-s-cooker".into(),
                        button: "on".into(),
                        gesture: Gesture::Press,
                    },
                    effect: Effect::SceneCycle { room: "kitchen-cooker".into() },
                },
                Binding {
                    name: "all-on".into(),
                    trigger: Trigger::Button {
                        device: "hue-s-all".into(),
                        button: "on".into(),
                        gesture: Gesture::Press,
                    },
                    effect: Effect::SceneCycle { room: "kitchen-all".into() },
                },
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
    fn power_below_cross_target_rejected() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("z2m-p-monitor", plug_dev("0xf1", "sonoff-power", &["on-off", "power"])),
                ("z2m-p-target", plug_dev("0xf2", "sonoff-power", &["on-off", "power"])),
            ],
            vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![Binding {
                name: "cross-kill".into(),
                trigger: Trigger::PowerBelow {
                    device: "z2m-p-monitor".into(),
                    watts: 5.0,
                    for_seconds: 300,
                },
                effect: Effect::TurnOff { target: "z2m-p-target".into() },
            }],
        );
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::PowerBelowCrossTarget { .. }));
    }

    #[test]
    fn transitive_descendants_through_rule_less_intermediate() {
        // grandparent → parent (rule-less) → child (with rules)
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-l-b", light("0xb")),
                ("hue-l-c", light("0xc")),
                ("hue-s-child", switch_dev("0x1")),
                ("hue-s-grand", switch_dev("0x2")),
            ],
            vec![
                room("child", 1, vec!["hue-l-a/11"], vec![], Some("parent")),
                room("parent", 2, vec!["hue-l-b/11"], vec![], Some("grand")),
                room("grand", 3, vec!["hue-l-c/11"], vec![], None),
            ],
            vec![
                Binding {
                    name: "child-on".into(),
                    trigger: Trigger::Button {
                        device: "hue-s-child".into(),
                        button: "on".into(),
                        gesture: Gesture::Press,
                    },
                    effect: Effect::SceneCycle { room: "child".into() },
                },
                Binding {
                    name: "grand-on".into(),
                    trigger: Trigger::Button {
                        device: "hue-s-grand".into(),
                        button: "on".into(),
                        gesture: Gesture::Press,
                    },
                    effect: Effect::SceneCycle { room: "grand".into() },
                },
            ],
        );
        let topo = Topology::build(&cfg).unwrap();
        // grand's descendants: child (parent is rule-less, filtered out)
        assert_eq!(topo.descendants_of("grand"), &["child".to_string()]);
        // parent's descendants: child
        assert_eq!(topo.descendants_of("parent"), &["child".to_string()]);
    }

    #[test]
    fn negative_double_tap_suppression_rejected() {
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([
                ("hue-l-a".into(), light("0xa")),
            ]),
            switch_models: default_switch_models(),
            rooms: vec![room("r", 1, vec!["hue-l-a/11"], vec![], None)],
            bindings: vec![],
            defaults: Defaults {
                double_tap_suppression_seconds: -1.0,
                ..Defaults::default()
            },
            heating: None,
            location: None,
        };
        assert_eq!(
            Topology::build(&cfg).unwrap_err(),
            TopologyError::NegativeDoubleTapSuppression(-1.0),
        );
    }

    #[test]
    fn soft_double_tap_buttons_tracked() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-s-a", switch_dev("0x1")),
            ],
            vec![room("study", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![
                Binding {
                    name: "study-on".into(),
                    trigger: Trigger::Button {
                        device: "hue-s-a".into(),
                        button: "on".into(),
                        gesture: Gesture::Press,
                    },
                    effect: Effect::SceneCycle { room: "study".into() },
                },
                Binding {
                    name: "all-off-dbl".into(),
                    trigger: Trigger::Button {
                        device: "hue-s-a".into(),
                        button: "on".into(),
                        gesture: Gesture::SoftDoubleTap,
                    },
                    effect: Effect::TurnOffAllZones,
                },
            ],
        );
        let topo = Topology::build(&cfg).unwrap();
        assert!(topo.is_soft_double_tap_button("hue-s-a", "on"));
        assert!(!topo.is_soft_double_tap_button("hue-s-a", "off"));
    }

    #[test]
    fn hw_double_tap_buttons_tracked() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("sonoff-orb", switch_dev_model("0x1", "test-hw-dbl")),
            ],
            vec![room("study", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![Binding {
                name: "orb-1".into(),
                trigger: Trigger::Button {
                    device: "sonoff-orb".into(),
                    button: "1".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::SceneCycle { room: "study".into() },
            }],
        );
        let topo = Topology::build(&cfg).unwrap();
        assert!(topo.is_hw_double_tap_button("sonoff-orb", "1"));
        assert!(topo.is_hw_double_tap_button("sonoff-orb", "2"));
    }

    #[test]
    fn hw_double_tap_is_per_button() {
        // Model where only button "1" has both press+double_tap,
        // button "2" only has press.
        let partial_model = SwitchModel {
            buttons: vec!["1".into(), "2".into()],
            z2m_action_map: BTreeMap::from([
                ("single_button_1".into(), ActionMapping { button: "1".into(), gesture: Gesture::Press }),
                ("single_button_2".into(), ActionMapping { button: "2".into(), gesture: Gesture::Press }),
                ("double_button_1".into(), ActionMapping { button: "1".into(), gesture: Gesture::DoubleTap }),
                // no double_button_2 — button "2" lacks HW double-tap
            ]),
        };
        let mut models = default_switch_models();
        models.insert("partial-dbl".into(), partial_model);
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            switch_models: models,
            devices: BTreeMap::from([
                ("hue-l-a".into(), light("0xa")),
                ("sw-partial".into(), switch_dev_model("0x1", "partial-dbl")),
            ]),
            rooms: vec![room("study", 1, vec!["hue-l-a/11"], vec![], None)],
            bindings: vec![Binding {
                name: "partial-1".into(),
                trigger: Trigger::Button {
                    device: "sw-partial".into(),
                    button: "1".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::SceneCycle { room: "study".into() },
            }],
            defaults: Defaults::default(),
            heating: None,
            location: None,
        };
        let topo = Topology::build(&cfg).unwrap();
        assert!(topo.is_hw_double_tap_button("sw-partial", "1"));
        assert!(!topo.is_hw_double_tap_button("sw-partial", "2"));
    }

    #[test]
    fn switch_model_lookup() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-s-a", switch_dev("0x1")),
            ],
            vec![room("study", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![],
        );
        let topo = Topology::build(&cfg).unwrap();
        assert_eq!(topo.switch_model_for("hue-s-a"), Some("test-dimmer"));
        assert_eq!(topo.switch_model_for("hue-l-a"), None);
    }

    #[test]
    fn unknown_switch_model_rejected() {
        let devices: BTreeMap<String, DeviceCatalogEntry> = BTreeMap::from([
            ("hue-l-a".into(), light("0xa")),
            ("hue-s-a".into(), DeviceCatalogEntry::Switch {
                common: CommonFields {
                    ieee_address: "0x1".into(),
                    description: None,
                    options: BTreeMap::new(),
                },
                model: "nonexistent-model".into(),
            }),
        ]);
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices,
            switch_models: default_switch_models(),
            rooms: vec![room("study", 1, vec!["hue-l-a/11"], vec![], None)],
            bindings: vec![],
            defaults: Default::default(),
            heating: None,
            location: None,
        };
        let err = Topology::build(&cfg).unwrap_err();
        assert!(matches!(err, TopologyError::UnknownSwitchModel { .. }));
    }

    #[test]
    fn all_switch_device_names_populated() {
        let cfg = config_with_bindings(
            vec![
                ("hue-l-a", light("0xa")),
                ("hue-s-a", switch_dev("0x1")),
                ("hue-s-b", switch_dev("0x2")),
            ],
            vec![room("study", 1, vec!["hue-l-a/11"], vec![], None)],
            vec![],
        );
        let topo = Topology::build(&cfg).unwrap();
        let names = topo.all_switch_device_names();
        assert!(names.contains("hue-s-a"));
        assert!(names.contains("hue-s-b"));
        assert!(!names.contains("hue-l-a"));
    }
}
