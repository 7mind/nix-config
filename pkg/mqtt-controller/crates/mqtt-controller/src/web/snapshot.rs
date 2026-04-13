//! Conversion from internal domain types ([`ZoneState`], [`PlugRuntimeState`])
//! to wire DTOs ([`RoomSnapshot`], [`PlugSnapshot`]).

use std::time::Instant;

use mqtt_controller_wire::{
    ActionDto, FullStateSnapshot, HeatingZoneInfo, HeatingZoneSnapshot, PlugSnapshot, RoomInfo,
    RoomSnapshot, SlotInfo, TopologyInfo, TrvSnapshot,
};

use crate::controller::Controller;
use crate::domain::action::{Action, ActionTarget};
use crate::topology::Topology;

/// Build a full state snapshot from the controller's current state.
pub fn build_full_snapshot(controller: &Controller, now: Instant) -> FullStateSnapshot {
    let topology = controller.topology();
    let hour = controller.clock().local_hour();
    let minute = controller.clock().local_minute();
    let sun = snapshot_sun_times(controller);
    let epoch_ms = controller.clock().epoch_millis();

    let rooms: Vec<RoomSnapshot> = topology
        .rooms()
        .map(|room| {
            let state = controller.state_for(&room.name);
            room_snapshot_from(room, state, hour, minute, sun.as_ref(), now)
        })
        .collect();

    let plugs: Vec<PlugSnapshot> = topology
        .all_plug_names()
        .iter()
        .map(|name| {
            let state = controller.plug_state_for(name);
            let idle_since_ago_ms = controller
                .earliest_kill_switch_idle(name)
                .map(|t| ago_ms(now, t));
            PlugSnapshot {
                device: name.clone(),
                on: state.map_or(false, |s| s.on),
                idle_since_ago_ms,
                power_watts: state.and_then(|s| s.last_power),
            }
        })
        .collect();

    let heating_zones = build_heating_zone_snapshots(controller, now);

    FullStateSnapshot {
        rooms,
        plugs,
        heating_zones,
        timestamp_epoch_ms: epoch_ms,
    }
}

/// Build a single room snapshot for incremental updates.
pub fn build_room_snapshot(
    controller: &Controller,
    room_name: &str,
    now: Instant,
) -> Option<RoomSnapshot> {
    let topology = controller.topology();
    let room = topology.room_by_name(room_name)?;
    let state = controller.state_for(room_name);
    let hour = controller.clock().local_hour();
    let minute = controller.clock().local_minute();
    let sun = snapshot_sun_times(controller);
    Some(room_snapshot_from(room, state, hour, minute, sun.as_ref(), now))
}

/// Compute sun times for snapshots (read-only path, no caching).
fn snapshot_sun_times(controller: &Controller) -> Option<crate::sun::SunTimes> {
    let loc = controller.location()?;
    let info = controller.clock().local_date_info();
    Some(crate::sun::compute_sun_times(loc, info.date, info.utc_offset_hours))
}

fn room_snapshot_from(
    room: &crate::topology::ResolvedRoom,
    state: Option<&crate::domain::state::ZoneState>,
    hour: u8,
    minute: u8,
    sun: Option<&crate::sun::SunTimes>,
    now: Instant,
) -> RoomSnapshot {
    let (active_slot, scene_ids) = room
        .scenes
        .slot_for_time(hour, minute, sun)
        .map(|(name, slot)| (Some(name.clone()), slot.scene_ids.clone()))
        .unwrap_or((None, Vec::new()));

    RoomSnapshot {
        name: room.name.clone(),
        group_name: room.group_name.clone(),
        physically_on: state.map_or(false, |s| s.physically_on),
        motion_owned: state.map_or(false, |s| s.motion_owned),
        cycle_idx: state.map_or(0, |s| s.cycle_idx),
        last_press_ago_ms: state
            .and_then(|s| s.last_press_at)
            .map(|t| ago_ms(now, t)),
        last_off_ago_ms: state
            .and_then(|s| s.last_off_at)
            .map(|t| ago_ms(now, t)),
        motion_active_sensors: state
            .map(|s| {
                s.motion_active_by_sensor
                    .iter()
                    .filter(|&(_, active)| *active)
                    .map(|(name, _)| name.clone())
                    .collect()
            })
            .unwrap_or_default(),
        active_slot,
        scene_ids,
    }
}

/// Build a single plug snapshot for incremental updates.
pub fn build_plug_snapshot(
    controller: &Controller,
    device: &str,
    now: Instant,
) -> Option<PlugSnapshot> {
    let state = controller.plug_state_for(device)?;
    let idle_since_ago_ms = controller
        .earliest_kill_switch_idle(device)
        .map(|t| ago_ms(now, t));
    Some(PlugSnapshot {
        device: device.to_string(),
        on: state.on,
        idle_since_ago_ms,
        power_watts: state.last_power,
    })
}

/// Build topology info for the frontend.
pub fn build_topology_info(topology: &Topology) -> TopologyInfo {
    let rooms: Vec<RoomInfo> = topology
        .rooms()
        .map(|room| RoomInfo {
            name: room.name.clone(),
            group_name: room.group_name.clone(),
            parent: room.parent.clone(),
            slots: room
                .scenes
                .slots
                .iter()
                .map(|(name, slot)| SlotInfo {
                    name: name.clone(),
                    from: slot.from.to_string(),
                    to: slot.to.to_string(),
                    scene_ids: slot.scene_ids.clone(),
                })
                .collect(),
            has_motion: room.has_motion_sensor(),
        })
        .collect();

    let plugs: Vec<String> = topology.all_plug_names().iter().cloned().collect();

    let heating_zones: Vec<HeatingZoneInfo> = topology
        .heating_config()
        .map(|cfg| {
            cfg.zones
                .iter()
                .map(|zone| HeatingZoneInfo {
                    name: zone.name.clone(),
                    relay_device: zone.relay.clone(),
                    trv_devices: zone.trvs.iter().map(|t| t.device.clone()).collect(),
                })
                .collect()
        })
        .unwrap_or_default();

    TopologyInfo {
        rooms,
        plugs,
        heating_zones,
    }
}

/// Convert an [`Action`] to a wire DTO.
pub fn action_to_dto(action: &Action) -> ActionDto {
    let (target_kind, target) = match &action.target {
        ActionTarget::Group(name) => ("group", name.as_str()),
        ActionTarget::Device(name) => ("device", name.as_str()),
        ActionTarget::DeviceGet(name) => ("device_get", name.as_str()),
    };
    ActionDto {
        target: target.to_string(),
        target_kind: target_kind.to_string(),
        payload_json: serde_json::to_string(&action.payload).unwrap_or_default(),
    }
}

/// Summarize an event for the decision log.
pub fn summarize_event(event: &crate::domain::event::Event) -> String {
    match event {
        crate::domain::event::Event::SwitchAction {
            device, action, ..
        } => format!("switch {action:?} on {device}"),
        crate::domain::event::Event::TapAction {
            device, button, action, ..
        } => {
            let kind = action.as_deref().unwrap_or("press");
            format!("tap {kind}_{button} on {device}")
        }
        crate::domain::event::Event::Occupancy {
            sensor,
            occupied,
            illuminance,
            ..
        } => {
            let lux = illuminance
                .map(|l| format!(", lux={l}"))
                .unwrap_or_default();
            let state = if *occupied { "active" } else { "inactive" };
            format!("motion {state} on {sensor}{lux}")
        }
        crate::domain::event::Event::GroupState { group, on, .. } => {
            let state = if *on { "ON" } else { "OFF" };
            format!("group state {state} for {group}")
        }
        crate::domain::event::Event::PlugState {
            device, on, power, ..
        } => {
            let state = if *on { "ON" } else { "OFF" };
            let watts = power
                .map(|w| format!(", {w:.1}W"))
                .unwrap_or_default();
            format!("plug state {state} for {device}{watts}")
        }
        crate::domain::event::Event::PlugPowerUpdate {
            device, watts, ..
        } => {
            format!("plug power {watts:.1}W for {device}")
        }
        crate::domain::event::Event::TrvState {
            device,
            local_temperature,
            pi_heating_demand,
            running_state,
            ..
        } => {
            let temp = local_temperature
                .map(|t| format!("{t:.1}°C"))
                .unwrap_or_else(|| "?".into());
            let demand = pi_heating_demand
                .map(|d| format!("{d}%"))
                .unwrap_or_else(|| "?".into());
            let rs = running_state.as_deref().unwrap_or("?");
            format!("trv {device}: {temp}, demand {demand}, {rs}")
        }
        crate::domain::event::Event::WallThermostatState {
            device, relay_on, ..
        } => {
            let state = relay_on
                .map(|on| if on { "ON" } else { "OFF" })
                .unwrap_or("?");
            format!("wall thermostat {device}: relay {state}")
        }
        crate::domain::event::Event::Tick { .. } => "tick".to_string(),
    }
}

/// Build snapshots for all heating zones.
fn build_heating_zone_snapshots(
    controller: &Controller,
    now: Instant,
) -> Vec<HeatingZoneSnapshot> {
    let Some(heating_cfg) = controller.topology().heating_config() else {
        return Vec::new();
    };
    let Some(heating_state) = controller.heating_state() else {
        return Vec::new();
    };
    heating_cfg
        .zones
        .iter()
        .map(|zone| build_one_heating_zone(zone, heating_state, now))
        .collect()
}

fn build_one_heating_zone(
    zone: &crate::config::heating::HeatingZone,
    heating_state: &crate::domain::heating_state::HeatingRuntimeState,
    now: Instant,
) -> HeatingZoneSnapshot {
    let zone_state = heating_state.zones.get(&zone.name);
    let relay_on = zone_state.map_or(false, |z| z.relay_on);
    let relay_state_known = zone_state.map_or(false, |z| z.relay_state_known);

    let trvs: Vec<TrvSnapshot> = zone
        .trvs
        .iter()
        .map(|zt| {
            let trv_state = zone_state.and_then(|z| z.trvs.get(&zt.device));
            TrvSnapshot {
                device: zt.device.clone(),
                local_temperature: trv_state.and_then(|t| t.local_temperature),
                pi_heating_demand: trv_state.and_then(|t| t.pi_heating_demand),
                running_state: trv_state
                    .map(|t| {
                        if !t.running_state_seen {
                            "unknown"
                        } else if t.running_state.is_heat() {
                            "heat"
                        } else {
                            "idle"
                        }
                    })
                    .unwrap_or("unknown")
                    .to_string(),
                setpoint: trv_state.and_then(|t| t.reported_setpoint),
                battery: trv_state.and_then(|t| t.battery),
                inhibited: trv_state.is_some_and(|t| t.is_inhibited(now)),
            }
        })
        .collect();

    // Wall thermostat temperature: not tracked in zone state (it arrives
    // via the Event, not stored separately). We leave it None for now;
    // the relay_on state is the main piece of information.
    HeatingZoneSnapshot {
        name: zone.name.clone(),
        relay_device: zone.relay.clone(),
        relay_on,
        relay_state_known,
        relay_temperature: None,
        trvs,
    }
}

/// Build a single heating zone snapshot for incremental updates.
pub fn build_heating_zone_snapshot(
    controller: &Controller,
    zone_name: &str,
    now: Instant,
) -> Option<HeatingZoneSnapshot> {
    let heating_cfg = controller.topology().heating_config()?;
    let heating_state = controller.heating_state()?;
    let zone = heating_cfg.zones.iter().find(|z| z.name == zone_name)?;
    Some(build_one_heating_zone(zone, heating_state, now))
}

/// Extract entity names from an event (before it is consumed by handle_event).
pub fn extract_event_entities(
    event: &crate::domain::event::Event,
    topology: &Topology,
) -> Vec<String> {
    let mut entities = Vec::new();
    match event {
        crate::domain::event::Event::SwitchAction { device, .. } => {
            entities.push(device.clone());
            for room in topology.rooms_for_switch(device) {
                entities.push(room.clone());
            }
        }
        crate::domain::event::Event::TapAction {
            device, button, ..
        } => {
            entities.push(device.clone());
            for room in topology.rooms_for_tap_button(device, *button) {
                entities.push(room.clone());
            }
        }
        crate::domain::event::Event::Occupancy { sensor, .. } => {
            entities.push(sensor.clone());
            for room in topology.rooms_for_motion(sensor) {
                entities.push(room.clone());
            }
        }
        crate::domain::event::Event::GroupState { group, .. } => {
            entities.push(group.clone());
            if let Some(room) = topology.room_by_group_name(group) {
                entities.push(room.name.clone());
            }
        }
        crate::domain::event::Event::PlugState { device, .. }
        | crate::domain::event::Event::PlugPowerUpdate { device, .. } => {
            entities.push(device.clone());
        }
        crate::domain::event::Event::TrvState { device, .. } => {
            entities.push(device.clone());
            if let Some(cfg) = topology.heating_config() {
                for zone in &cfg.zones {
                    if zone.trvs.iter().any(|t| t.device == *device) {
                        entities.push(zone.name.clone());
                    }
                }
            }
        }
        crate::domain::event::Event::WallThermostatState { device, .. } => {
            entities.push(device.clone());
            if let Some(cfg) = topology.heating_config() {
                for zone in &cfg.zones {
                    if zone.relay == *device {
                        entities.push(zone.name.clone());
                    }
                }
            }
        }
        crate::domain::event::Event::Tick { .. } => {}
    }
    entities
}

/// Combine event entities with action-target entities into a deduped list.
pub fn finish_involved_entities(
    mut entities: Vec<String>,
    actions: &[crate::domain::action::Action],
    topology: &Topology,
) -> Vec<String> {
    for action in actions {
        let target_name = match &action.target {
            crate::domain::action::ActionTarget::Group(name) => name,
            crate::domain::action::ActionTarget::Device(name) => name,
            crate::domain::action::ActionTarget::DeviceGet(name) => name,
        };
        entities.push(target_name.clone());
        if let crate::domain::action::ActionTarget::Group(group) = &action.target {
            if let Some(room) = topology.room_by_group_name(group) {
                entities.push(room.name.clone());
            }
        }
    }
    entities.sort();
    entities.dedup();
    entities
}

fn ago_ms(now: Instant, then: Instant) -> u64 {
    now.duration_since(then).as_millis() as u64
}

