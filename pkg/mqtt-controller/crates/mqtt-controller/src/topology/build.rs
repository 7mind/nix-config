//! Topology validation + indexing. The single entry point is
//! [`super::Topology::build`]; everything else in this file is the
//! one-shot validation pipeline that turns a raw [`Config`] into the
//! cross-checked and indexed runtime view.
//!
//! Most validation logic mirrors the existing `defineRooms` validation in
//! `private/hosts/raspi5m/mqtt-controller-tools.nix` — the Rust layer
//! runs its own as a defense-in-depth check at startup.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use crate::config::catalog::PlugProtocol;
use crate::config::switch_model::Gesture;
use crate::config::{Config, DeviceCatalogEntry, Room, Trigger};

use super::{
    FriendlyName, MotionBinding, ResolvedBinding, ResolvedRoom, RoomName, Topology, TopologyError,
};

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
