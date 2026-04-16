//! Event-log helpers for the web dashboard's decision-trace stream.
//!
//! These convert domain types ([`Event`], [`Action`]) into the wire DTOs
//! the frontend renders. Distinct from `web::snapshot`, which builds
//! periodic state snapshots; the event-log path runs once per processed
//! event.

use mqtt_controller_wire::ActionDto;

use crate::domain::action::{Action, ActionTarget};
use crate::topology::Topology;

/// Convert an [`Action`] to a wire DTO.
pub fn action_to_dto(action: &Action) -> ActionDto {
    let (target_kind, target) = match &action.target {
        ActionTarget::Group(name) => ("group", name.as_str()),
        ActionTarget::Device(name) => ("device", name.as_str()),
        ActionTarget::DeviceGet(name) => ("device_get", name.as_str()),
        ActionTarget::Raw { topic, .. } => ("raw", topic.as_str()),
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
        crate::domain::event::Event::ButtonPress {
            device, button, gesture, ..
        } => format!("button {gesture:?} {button} on {device}"),
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

/// Extract entity names from an event (before it is consumed by handle_event).
pub fn extract_event_entities(
    event: &crate::domain::event::Event,
    topology: &Topology,
) -> Vec<String> {
    let mut entities = Vec::new();
    match event {
        crate::domain::event::Event::ButtonPress {
            device, button, gesture, ..
        } => {
            entities.push(device.clone());
            // Derive related rooms from bindings for this button event.
            for &idx in topology.bindings_for_button(device, button, *gesture) {
                let binding = &topology.bindings()[idx];
                if let Some(room) = binding.effect.room() {
                    entities.push(room.to_string());
                }
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
            crate::domain::action::ActionTarget::Raw { .. } => continue,
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
