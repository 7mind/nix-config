//! Event-log helpers for the web dashboard's decision-trace stream.
//!
//! These convert domain types ([`Event`], [`Effect`]) into the wire DTOs
//! the frontend renders. Distinct from `web::snapshot`, which builds
//! periodic state snapshots; the event-log path runs once per processed
//! event.

use mqtt_controller_wire::ActionDto;

use crate::domain::Effect;
use crate::topology::Topology;

/// Convert an [`Effect`] to a wire DTO for the event log.
pub fn effect_to_dto(effect: &Effect, topology: &Topology) -> ActionDto {
    match effect {
        Effect::PublishGroupSet { room, payload } => {
            let target = topology.room(*room).group_name.clone();
            ActionDto {
                target,
                target_kind: "group".into(),
                payload_json: serde_json::to_string(payload).unwrap_or_default(),
            }
        }
        Effect::PublishDeviceSet { device, payload } => ActionDto {
            target: topology.device_name(*device).to_string(),
            target_kind: "device".into(),
            payload_json: serde_json::to_string(payload).unwrap_or_default(),
        },
        Effect::PublishDeviceGet { device } => ActionDto {
            target: topology.device_name(*device).to_string(),
            target_kind: "device_get".into(),
            payload_json: r#"{"state":""}"#.into(),
        },
        Effect::PublishHaDiscoveryZone { zone } => {
            let name = topology
                .heating_config()
                .map(|cfg| cfg.zones[zone.as_usize()].name.clone())
                .unwrap_or_default();
            ActionDto {
                target: name,
                target_kind: "raw".into(),
                payload_json: "<discovery>".into(),
            }
        }
        Effect::PublishHaDiscoveryTrv { trv } => ActionDto {
            target: topology.device_name(*trv).to_string(),
            target_kind: "raw".into(),
            payload_json: "<discovery>".into(),
        },
        Effect::PublishHaStateZone { zone, state } => {
            let name = topology
                .heating_config()
                .map(|cfg| cfg.zones[zone.as_usize()].name.clone())
                .unwrap_or_default();
            ActionDto {
                target: name,
                target_kind: "raw".into(),
                payload_json: state.to_string(),
            }
        }
        Effect::PublishHaStateTrv { trv, state } => ActionDto {
            target: topology.device_name(*trv).to_string(),
            target_kind: "raw".into(),
            payload_json: state.to_string(),
        },
        Effect::PublishRaw { topic, payload, .. } => ActionDto {
            target: topic.clone(),
            target_kind: "raw".into(),
            payload_json: payload.clone(),
        },
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
        crate::domain::event::Event::LightState { device, on, brightness, .. } => {
            let b = brightness.map(|b| format!(" bri={b}")).unwrap_or_default();
            format!("light {device}: {}{b}", if *on { "ON" } else { "OFF" })
        }
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
            if let Some(device_idx) = topology.device_idx(device) {
                for &idx in topology.bindings_for_button(device_idx, button, *gesture) {
                    let binding = topology.binding(idx);
                    if let Some(room_idx) = binding.effect.room() {
                        entities.push(topology.room(room_idx).name.clone());
                    }
                }
            }
        }
        crate::domain::event::Event::Occupancy { sensor, .. } => {
            entities.push(sensor.clone());
            for &room_idx in topology.rooms_for_motion(sensor) {
                entities.push(topology.room(room_idx).name.clone());
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
        crate::domain::event::Event::LightState { device, .. } => {
            entities.push(device.clone());
            // Also include the zone the light belongs to so the filter
            // can surface it on the room's card.
            for room in topology.rooms() {
                for member in &room.members {
                    let m = member.split('/').next().unwrap_or(member);
                    if m == device {
                        entities.push(room.name.clone());
                        break;
                    }
                }
            }
        }
    }
    entities
}

/// Combine event entities with effect-target entities into a deduped list.
pub fn finish_involved_entities(
    mut entities: Vec<String>,
    effects: &[Effect],
    topology: &Topology,
) -> Vec<String> {
    for effect in effects {
        match effect {
            Effect::PublishGroupSet { room, .. } => {
                let r = topology.room(*room);
                entities.push(r.group_name.clone());
                entities.push(r.name.clone());
            }
            Effect::PublishDeviceSet { device, .. }
            | Effect::PublishDeviceGet { device } => {
                entities.push(topology.device_name(*device).to_string());
            }
            Effect::PublishHaDiscoveryZone { .. }
            | Effect::PublishHaDiscoveryTrv { .. }
            | Effect::PublishHaStateZone { .. }
            | Effect::PublishHaStateTrv { .. }
            | Effect::PublishRaw { .. } => {
                // Raw publishes don't have an addressable entity in
                // the usual sense; skip.
            }
        }
    }
    entities.sort();
    entities.dedup();
    entities
}
