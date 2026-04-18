//! Z2M state seed: prime every zigbee entity's actual state from z2m's
//! WebSocket `/api` in a single round-trip. Replaces the former
//! retained-drain + `/get` cascade (phases 1, 2+3, 3b, 5 of the old
//! startup refresh).
//!
//! Classifies each `(friendly_name, state)` entry from the bulk dump
//! against the topology and routes it to the right `Event` variant —
//! `GroupState`, `LightState`, `PlugState`, `TrvState`,
//! `WallThermostatState`, `Occupancy`. Everything z2m publishes flows
//! through the same `handle_event` path as a runtime echo, so the TASS
//! accounting (freshness/phase transitions, kill-switch arming, etc.)
//! stays uniform.
//!
//! Failure is non-fatal: the caller logs and continues. The wildcard
//! MQTT subscription is already active, so any future publish will
//! populate the missing state.

use std::time::Duration;

use serde_json::Value;

use crate::domain::event::Event;
use crate::logic::EventProcessor;
use crate::mqtt::z2m_api;
use crate::time::Clock;
use crate::topology::Topology;

/// Seed z2m entity state via the WebSocket API. Returns a summary of
/// what was populated.
pub async fn seed_z2m_state(
    processor: &mut EventProcessor,
    topology: &Topology,
    ws_url: &str,
    clock: &dyn Clock,
    timeout: Duration,
    attempts: u32,
    retry_delay: Duration,
) -> anyhow::Result<SeedSummary> {
    let states = z2m_api::fetch_device_states_with_retry(ws_url, timeout, attempts, retry_delay)
        .await?;

    let now = clock.now();
    let mut s = SeedSummary::default();
    for (name, payload) in states {
        // Multiple classifications are possible (e.g. a device that's
        // both a plug and a light is theoretically representable); the
        // checks fall through in catalog-specific order. Motion sensor
        // check comes last because `rooms_for_motion` scans all
        // bindings, which is more expensive than the direct lookups.
        if topology.room_by_group_name(&name).is_some() {
            if let Some(ev) = group_event(&name, &payload, now) {
                processor.handle_event(ev);
                s.groups += 1;
            }
        } else if topology.is_plug(&name) && !topology.is_zwave_plug(&name) {
            if let Some(ev) = plug_event(&name, &payload, now) {
                processor.handle_event(ev);
                s.plugs += 1;
            }
        } else if topology.is_trv(&name) {
            if let Some(ev) = trv_event(&name, &payload, now) {
                processor.handle_event(ev);
                s.trvs += 1;
            }
        } else if topology.is_wall_thermostat(&name) {
            if let Some(ev) = wall_thermostat_event(&name, &payload, now) {
                processor.handle_event(ev);
                s.wall_thermostats += 1;
            }
        } else if topology.is_light(&name) {
            if let Some(ev) = light_event(&name, &payload, now) {
                processor.handle_event(ev);
                s.lights += 1;
            }
        } else if !topology.rooms_for_motion(&name).is_empty() {
            if let Some(ev) = occupancy_event(&name, &payload, now) {
                processor.handle_event(ev);
                s.motion_sensors += 1;
            }
        } else {
            s.ignored += 1;
        }
    }
    Ok(s)
}

/// Summary of a single seed pass. Fields are public so the caller can
/// fold them into a structured log line.
#[derive(Debug, Default)]
pub struct SeedSummary {
    pub groups: u32,
    pub lights: u32,
    pub plugs: u32,
    pub trvs: u32,
    pub wall_thermostats: u32,
    pub motion_sensors: u32,
    /// Devices z2m reports that don't match anything in our catalog.
    pub ignored: u32,
}

fn group_event(group: &str, payload: &Value, now: std::time::Instant) -> Option<Event> {
    let on = read_on_off(payload)?;
    Some(Event::GroupState {
        group: group.to_string(),
        on,
        ts: now,
    })
}

fn plug_event(device: &str, payload: &Value, now: std::time::Instant) -> Option<Event> {
    let on = read_on_off(payload)?;
    let power = payload.get("power").and_then(|v| v.as_f64());
    Some(Event::PlugState {
        device: device.to_string(),
        on,
        power,
        ts: now,
    })
}

fn light_event(device: &str, payload: &Value, now: std::time::Instant) -> Option<Event> {
    let on = read_on_off(payload)?;
    let brightness = payload
        .get("brightness")
        .and_then(|v| v.as_u64())
        .map(|n| n.min(255) as u8);
    let color_temp = payload
        .get("color_temp")
        .and_then(|v| v.as_u64())
        .map(|n| n.min(u16::MAX as u64) as u16);
    let color_xy = payload.get("color").and_then(|c| {
        let x = c.get("x")?.as_f64()?;
        let y = c.get("y")?.as_f64()?;
        Some((x, y))
    });
    Some(Event::LightState {
        device: device.to_string(),
        on,
        brightness,
        color_temp,
        color_xy,
        ts: now,
    })
}

fn trv_event(device: &str, payload: &Value, now: std::time::Instant) -> Option<Event> {
    // A TRV payload arriving via the bulk WS dump may be missing fields
    // the device hasn't yet reported; accept whatever is there. At
    // least one numeric climate field is a sanity threshold — skip
    // empty objects.
    let local_temperature = payload.get("local_temperature").and_then(|v| v.as_f64());
    let pi_heating_demand = payload
        .get("pi_heating_demand")
        .and_then(|v| v.as_u64())
        .map(|n| n.min(100) as u8);
    let running_state = payload
        .get("running_state")
        .and_then(|v| v.as_str())
        .map(String::from);
    let occupied_heating_setpoint = payload
        .get("occupied_heating_setpoint")
        .and_then(|v| v.as_f64());
    let operating_mode = payload
        .get("operating_mode")
        .and_then(|v| v.as_str())
        .map(String::from);
    let battery = payload
        .get("battery")
        .and_then(|v| v.as_u64())
        .map(|n| n.min(100) as u8);

    let any_field = local_temperature.is_some()
        || pi_heating_demand.is_some()
        || running_state.is_some()
        || occupied_heating_setpoint.is_some()
        || operating_mode.is_some()
        || battery.is_some();
    if !any_field {
        return None;
    }
    Some(Event::TrvState {
        device: device.to_string(),
        local_temperature,
        pi_heating_demand,
        running_state,
        occupied_heating_setpoint,
        operating_mode,
        battery,
        ts: now,
    })
}

fn wall_thermostat_event(device: &str, payload: &Value, now: std::time::Instant) -> Option<Event> {
    let relay_on = payload
        .get("state")
        .and_then(|v| v.as_str())
        .map(|s| s.eq_ignore_ascii_case("ON"));
    let local_temperature = payload.get("local_temperature").and_then(|v| v.as_f64());
    let operating_mode = payload
        .get("operating_mode")
        .and_then(|v| v.as_str())
        .map(String::from);
    if relay_on.is_none() && local_temperature.is_none() && operating_mode.is_none() {
        return None;
    }
    Some(Event::WallThermostatState {
        device: device.to_string(),
        relay_on,
        local_temperature,
        operating_mode,
        ts: now,
    })
}

fn occupancy_event(sensor: &str, payload: &Value, now: std::time::Instant) -> Option<Event> {
    let occupied = payload.get("occupancy")?.as_bool()?;
    let illuminance = payload
        .get("illuminance")
        .and_then(|v| v.as_u64())
        .map(|n| n as u32);
    Some(Event::Occupancy {
        sensor: sensor.to_string(),
        occupied,
        illuminance,
        ts: now,
    })
}

/// Read the ubiquitous `{"state": "ON"|"OFF"}` field and return
/// `true`/`false`. Returns `None` for anything else (missing, different
/// type, weird string).
fn read_on_off(payload: &Value) -> Option<bool> {
    let s = payload.get("state")?.as_str()?;
    Some(s.eq_ignore_ascii_case("ON"))
}

#[cfg(test)]
#[path = "z2m_seed_tests.rs"]
mod tests;
