//! Conversion from internal domain types ([`ZoneState`], [`PlugRuntimeState`])
//! to wire DTOs ([`RoomSnapshot`], [`PlugSnapshot`]).

use std::time::Instant;

use hue_wire::{
    ActionDto, FullStateSnapshot, PlugSnapshot, RoomInfo, RoomSnapshot, SlotInfo, TopologyInfo,
};

use crate::controller::Controller;
use crate::domain::action::{Action, ActionTarget};
use crate::topology::Topology;

/// Build a full state snapshot from the controller's current state.
pub fn build_full_snapshot(controller: &Controller, now: Instant) -> FullStateSnapshot {
    let topology = controller.topology();
    let hour = controller.clock().local_hour();
    let epoch_ms = controller.clock().epoch_millis();

    let rooms: Vec<RoomSnapshot> = topology
        .rooms()
        .map(|room| {
            let state = controller.state_for(&room.name);
            room_snapshot_from(room, state, hour, now)
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

    FullStateSnapshot {
        rooms,
        plugs,
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
    Some(room_snapshot_from(room, state, hour, now))
}

fn room_snapshot_from(
    room: &crate::topology::ResolvedRoom,
    state: Option<&crate::domain::state::ZoneState>,
    hour: u8,
    now: Instant,
) -> RoomSnapshot {
    let (active_slot, scene_ids) = room
        .scenes
        .slot_for_hour(hour)
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
                    start_hour: slot.start_hour,
                    end_hour_exclusive: slot.end_hour_exclusive,
                    scene_ids: slot.scene_ids.clone(),
                })
                .collect(),
            has_motion: room.has_motion_sensor(),
        })
        .collect();

    let plugs: Vec<String> = topology.all_plug_names().iter().cloned().collect();

    TopologyInfo { rooms, plugs }
}

/// Convert an [`Action`] to a wire DTO.
pub fn action_to_dto(action: &Action) -> ActionDto {
    let (target_kind, target) = match &action.target {
        ActionTarget::Group(name) => ("group", name.as_str()),
        ActionTarget::Device(name) => ("device", name.as_str()),
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

fn ago_ms(now: Instant, then: Instant) -> u64 {
    now.duration_since(then).as_millis() as u64
}

