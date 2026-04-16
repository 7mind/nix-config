//! Topology validation + indexing. The single entry point is
//! [`super::Topology::build`]; everything else in this file is the
//! one-shot validation pipeline that turns a raw [`Config`] into the
//! cross-checked and indexed runtime view.
//!
//! Most validation logic mirrors the existing `defineRooms` validation in
//! `private/hosts/raspi5m/mqtt-controller-tools.nix` — the Rust layer
//! runs its own as a defense-in-depth check at startup.

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::time::Duration;

use crate::config::catalog::PlugProtocol;
use crate::config::switch_model::Gesture;
use crate::config::{Config, DeviceCatalogEntry, Effect, Room, Trigger};

use super::{
    BindingIdx, DeviceIdx, DeviceInfo, DeviceKind, FriendlyName, MotionBinding, PlugIdx,
    ResolvedBinding, ResolvedEffect, ResolvedRoom, ResolvedTrigger, RoomIdx, RoomName, Topology,
    TopologyError,
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

        // 6. Build the Vec<DeviceInfo> indexed catalog. Sorted by
        //    friendly_name so iteration is deterministic.
        let mut device_pairs: Vec<(&String, &DeviceCatalogEntry)> = config.devices.iter().collect();
        device_pairs.sort_by(|a, b| a.0.cmp(b.0));
        let mut devices: Vec<DeviceInfo> = Vec::with_capacity(device_pairs.len());
        let mut device_by_name: BTreeMap<String, DeviceIdx> = BTreeMap::new();
        for (i, (name, entry)) in device_pairs.iter().enumerate() {
            let kind = DeviceKind::from_entry(entry);
            let plug_protocol = entry.plug_protocol();
            let switch_model = entry.switch_model().map(str::to_string);
            devices.push(DeviceInfo {
                name: (*name).clone(),
                kind,
                plug_protocol,
                switch_model,
            });
            device_by_name.insert((*name).clone(), DeviceIdx::new(i as u32));
        }

        // 6b. Validate switch model references and collect hw_double_tap
        //     entries from the catalog. Both depend only on the catalog,
        //     not on bindings.
        let mut hw_double_tap_buttons: BTreeSet<(DeviceIdx, String)> = BTreeSet::new();
        for (name, entry) in &config.devices {
            if let DeviceCatalogEntry::Switch { model, .. } = entry {
                let switch_model = config.switch_models.get(model).ok_or_else(|| {
                    TopologyError::UnknownSwitchModel {
                        device: name.clone(),
                        model: model.clone(),
                    }
                })?;
                let dev_idx = device_by_name[name];
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
                        hw_double_tap_buttons.insert((dev_idx, button.clone()));
                    }
                }
            }
        }

        // 6c. Build the device-kind subset Vec<DeviceIdx>'s plus the
        //     Z-Wave node_id → DeviceIdx map.
        let mut switch_devices: Vec<DeviceIdx> = Vec::new();
        let mut motion_sensor_devices: Vec<DeviceIdx> = Vec::new();
        let mut plug_devices: Vec<DeviceIdx> = Vec::new();
        let mut zigbee_plug_devices: Vec<DeviceIdx> = Vec::new();
        let mut zwave_plug_devices: Vec<DeviceIdx> = Vec::new();
        let mut trv_devices: Vec<DeviceIdx> = Vec::new();
        let mut wall_thermostat_devices: Vec<DeviceIdx> = Vec::new();
        let mut zwave_node_id_to_device: BTreeMap<u16, DeviceIdx> = BTreeMap::new();
        for (i, info) in devices.iter().enumerate() {
            let idx = DeviceIdx::new(i as u32);
            match info.kind {
                DeviceKind::Switch => switch_devices.push(idx),
                DeviceKind::MotionSensor => motion_sensor_devices.push(idx),
                DeviceKind::Plug => {
                    plug_devices.push(idx);
                    match info.plug_protocol.unwrap_or_default() {
                        PlugProtocol::Zigbee => zigbee_plug_devices.push(idx),
                        PlugProtocol::Zwave => {
                            zwave_plug_devices.push(idx);
                        }
                    }
                }
                DeviceKind::Trv => trv_devices.push(idx),
                DeviceKind::WallThermostat => wall_thermostat_devices.push(idx),
                DeviceKind::Light => {}
            }
        }
        // Validate Z-Wave plugs have node_id and uniqueness.
        for &idx in &zwave_plug_devices {
            let info = &devices[idx.as_usize()];
            let entry = &config.devices[&info.name];
            let node_id = entry.zwave_node_id().ok_or_else(|| {
                TopologyError::ZwavePlugMissingNodeId {
                    device: info.name.clone(),
                }
            })?;
            if let Some(&existing_idx) = zwave_node_id_to_device.get(&node_id) {
                return Err(TopologyError::DuplicateZwaveNodeId {
                    node_id,
                    first: devices[existing_idx.as_usize()].name.clone(),
                    second: info.name.clone(),
                });
            }
            zwave_node_id_to_device.insert(node_id, idx);
        }

        // 7. Motion sensor bindings from room.motion_sensors. Build the
        //    motion_index keyed by DeviceIdx. We also collect each
        //    room's bound_motion list for the ResolvedRoom assembly.
        let mut motion_index: BTreeMap<DeviceIdx, Vec<RoomIdx>> = BTreeMap::new();
        let mut bound_motion_per_room: BTreeMap<RoomName, Vec<MotionBinding>> = BTreeMap::new();

        for (room_pos, room) in config.rooms.iter().enumerate() {
            let room_idx = RoomIdx::new(room_pos as u32);
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
                        let sensor_idx = device_by_name[sensor_name];
                        motion_index
                            .entry(sensor_idx)
                            .or_default()
                            .push(room_idx);
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

        // 8. Build room_by_name and room_by_group_name maps (assignment
        //    in config order).
        let mut room_by_name: BTreeMap<RoomName, RoomIdx> = BTreeMap::new();
        let mut room_by_group_name: BTreeMap<FriendlyName, RoomIdx> = BTreeMap::new();
        for (i, room) in config.rooms.iter().enumerate() {
            let idx = RoomIdx::new(i as u32);
            room_by_name.insert(room.name.clone(), idx);
            room_by_group_name.insert(room.group_name.clone(), idx);
        }

        // 9. Validate bindings, translate into resolved form, build
        //    dispatch indexes.
        let mut binding_names: BTreeSet<String> = BTreeSet::new();
        let mut resolved_bindings: Vec<ResolvedBinding> = Vec::new();
        let mut button_binding_index: BTreeMap<(DeviceIdx, String, Gesture), Vec<BindingIdx>> =
            BTreeMap::new();
        let mut power_below_index: BTreeMap<DeviceIdx, Vec<BindingIdx>> = BTreeMap::new();
        let mut soft_double_tap_buttons: BTreeSet<(DeviceIdx, String)> = BTreeSet::new();
        let mut room_has_bindings_set: BTreeSet<RoomIdx> = BTreeSet::new();

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

            // First validate, then translate. Both produce the same
            // outcome for valid configs; validation errors take precedence.
            let resolved_trigger = match &rule.trigger {
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
                    let dev_idx = device_by_name[device];
                    if *gesture == Gesture::SoftDoubleTap {
                        soft_double_tap_buttons.insert((dev_idx, button.clone()));
                    }
                    ResolvedTrigger::Button {
                        device: dev_idx,
                        button: button.clone(),
                        gesture: *gesture,
                    }
                }
                Trigger::PowerBelow { device, watts, for_seconds } => {
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
                    let dev_idx = device_by_name[device];
                    let plug_idx = PlugIdx::from_device(dev_idx);
                    ResolvedTrigger::PowerBelow {
                        plug: plug_idx,
                        watts: *watts,
                        holdoff: Duration::from_secs(*for_seconds),
                    }
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
                    ResolvedTrigger::At { time: time.clone() }
                }
            };

            // Validate room-targeting effects: the room must exist.
            if let Some(room_name) = rule.effect.room() {
                if !room_by_name.contains_key(room_name) {
                    return Err(TopologyError::BindingRoomNotFound {
                        binding: rule.name.clone(),
                        room: room_name.to_string(),
                    });
                }
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

            let resolved_effect = match &rule.effect {
                Effect::SceneCycle { room } => ResolvedEffect::SceneCycle { room: room_by_name[room] },
                Effect::SceneToggle { room } => ResolvedEffect::SceneToggle { room: room_by_name[room] },
                Effect::SceneToggleCycle { room } => {
                    ResolvedEffect::SceneToggleCycle { room: room_by_name[room] }
                }
                Effect::TurnOffRoom { room } => ResolvedEffect::TurnOffRoom { room: room_by_name[room] },
                Effect::BrightnessStep { room, step, transition } => ResolvedEffect::BrightnessStep {
                    room: room_by_name[room],
                    step: *step,
                    transition: *transition,
                },
                Effect::BrightnessMove { room, rate } => {
                    ResolvedEffect::BrightnessMove { room: room_by_name[room], rate: *rate }
                }
                Effect::BrightnessStop { room } => ResolvedEffect::BrightnessStop { room: room_by_name[room] },
                Effect::Toggle { target, confirm_off_seconds } => {
                    let dev_idx = device_by_name[target];
                    ResolvedEffect::Toggle {
                        plug: PlugIdx::from_device(dev_idx),
                        confirm_off_seconds: *confirm_off_seconds,
                    }
                }
                Effect::TurnOn { target } => {
                    let dev_idx = device_by_name[target];
                    ResolvedEffect::TurnOn { plug: PlugIdx::from_device(dev_idx) }
                }
                Effect::TurnOff { target } => {
                    let dev_idx = device_by_name[target];
                    ResolvedEffect::TurnOff { plug: PlugIdx::from_device(dev_idx) }
                }
                Effect::TurnOffAllZones => ResolvedEffect::TurnOffAllZones,
            };

            // Track which rooms have bindings (for descendant filtering).
            if let Some(room_idx) = resolved_effect.room() {
                room_has_bindings_set.insert(room_idx);
            }

            let binding_idx = BindingIdx::new(resolved_bindings.len() as u32);
            // Build dispatch indexes from the resolved trigger.
            match &resolved_trigger {
                ResolvedTrigger::Button { device, button, gesture } => {
                    button_binding_index
                        .entry((*device, button.clone(), *gesture))
                        .or_default()
                        .push(binding_idx);
                }
                ResolvedTrigger::PowerBelow { plug, .. } => {
                    power_below_index
                        .entry(plug.device())
                        .or_default()
                        .push(binding_idx);
                }
                ResolvedTrigger::At { .. } => {}
            }

            resolved_bindings.push(ResolvedBinding {
                name: rule.name.clone(),
                trigger: resolved_trigger,
                effect: resolved_effect,
            });
        }

        // 10. Build resolved rooms in config order.
        let mut rooms: Vec<ResolvedRoom> = Vec::with_capacity(config.rooms.len());
        for room in &config.rooms {
            let bound_motion = bound_motion_per_room
                .remove(&room.name)
                .unwrap_or_default();
            rooms.push(ResolvedRoom {
                name: room.name.clone(),
                group_name: room.group_name.clone(),
                id: room.id,
                members: room.members.clone(),
                parent: room.parent.clone(),
                scenes: room.scenes.clone(),
                off_transition_seconds: room.off_transition_seconds,
                motion_off_cooldown_seconds: room.motion_off_cooldown_seconds,
                bound_motion,
            });
        }

        // 10b. room_has_bindings indexed by RoomIdx.
        let room_has_bindings: Vec<bool> = (0..rooms.len())
            .map(|i| room_has_bindings_set.contains(&RoomIdx::new(i as u32)))
            .collect();

        // 11. Transitive descendants. Walk each room and gather every
        //    room reachable via the *inverse* of the parent edge.
        //    Filter to descendants with rules so the controller doesn't
        //    waste cycles propagating to rule-less rooms.
        let mut direct_children: BTreeMap<RoomIdx, Vec<RoomIdx>> = BTreeMap::new();
        for (i, room) in rooms.iter().enumerate() {
            let idx = RoomIdx::new(i as u32);
            if let Some(parent_name) = &room.parent {
                let parent_idx = room_by_name[parent_name];
                direct_children.entry(parent_idx).or_default().push(idx);
            }
        }
        // Determine which rooms have rules (motion sensors OR bindings).
        let room_has_rules_vec: Vec<bool> = rooms
            .iter()
            .enumerate()
            .map(|(i, room)| {
                !room.bound_motion.is_empty() || room_has_bindings[i]
            })
            .collect();

        let descendants_by_room: Vec<Vec<RoomIdx>> = (0..rooms.len())
            .map(|i| {
                let parent_idx = RoomIdx::new(i as u32);
                let mut out: Vec<RoomIdx> = Vec::new();
                let mut seen: HashSet<RoomIdx> = HashSet::new();
                let mut stack: Vec<RoomIdx> = direct_children
                    .get(&parent_idx)
                    .cloned()
                    .unwrap_or_default();
                while let Some(curr) = stack.pop() {
                    if !seen.insert(curr) {
                        continue;
                    }
                    if room_has_rules_vec[curr.as_usize()] {
                        out.push(curr);
                    }
                    if let Some(grandkids) = direct_children.get(&curr) {
                        stack.extend(grandkids.iter().copied());
                    }
                }
                // Sort by name for deterministic test output (matches old
                // BTreeMap-ordered behavior).
                out.sort_by(|a, b| {
                    rooms[a.as_usize()]
                        .name
                        .cmp(&rooms[b.as_usize()].name)
                });
                out
            })
            .collect();

        // 12. Validate heating config if present.
        let trv_names_set: BTreeSet<&str> = trv_devices
            .iter()
            .map(|&i| devices[i.as_usize()].name.as_str())
            .collect();
        let wall_thermostat_names_set: BTreeSet<&str> = wall_thermostat_devices
            .iter()
            .map(|&i| devices[i.as_usize()].name.as_str())
            .collect();
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
                if !wall_thermostat_names_set.contains(zone.relay.as_str()) {
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
                    if !trv_names_set.contains(zt.device.as_str()) {
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

        // Location is required if any schedule slot or At trigger uses sun expressions.
        if needs_location && config.location.is_none() {
            return Err(TopologyError::MissingLocationForSunExpressions);
        }

        Ok(Self {
            rooms,
            room_by_name,
            room_by_group_name,
            descendants_by_room,
            room_has_bindings,
            devices,
            device_by_name,
            switch_devices,
            motion_sensor_devices,
            plug_devices,
            zigbee_plug_devices,
            zwave_plug_devices,
            trv_devices,
            wall_thermostat_devices,
            zwave_node_id_to_device,
            switch_models: config.switch_models.clone(),
            soft_double_tap_buttons,
            hw_double_tap_buttons,
            bindings: resolved_bindings,
            button_binding_index,
            power_below_index,
            motion_index,
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
