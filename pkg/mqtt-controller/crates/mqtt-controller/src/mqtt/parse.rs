//! Translate raw MQTT publishes into domain [`Event`]s. Both
//! [`parse_event`] and the inner [`parse_zwave_event`] tolerate
//! `None` for anything they don't recognise — we never panic on
//! garbage from the broker.

use std::time::Instant;

use rumqttc::Publish;

use super::codec;
use crate::domain::event::Event;
use crate::time::Clock;
use crate::topology::Topology;

/// Translate a raw MQTT publish into an [`Event`]. Returns `None` for
/// messages we don't care about (unknown topic, malformed payload,
/// unrecognized action). The whole controller/runtime tolerates `None`
/// — we never panic on bad input from the broker.
pub(super) fn parse_event(topology: &Topology, p: &Publish, clock: &dyn Clock) -> Option<Event> {
    // QoS 1 redeliveries arrive with DUP=1 whenever the broker didn't
    // observe our PUBACK. The MQTT spec allows the same payload to be
    // delivered more than once, so client-side dedup is the standard
    // way to make downstream handling idempotent. Filtering at parse
    // time means every consumer (motion, button, plug, heating) gets
    // the guarantee for free — no per-handler content hashing needed.
    //
    // A duplicate button action would fire its binding twice (e.g.
    // a cycleOnDoubleTap press becoming two scene_toggles); a
    // duplicate occupancy publish would look like a fresh false→true
    // edge if the sensor's prior state had been cleared. The motion
    // handler has its own same-state dedup as defence-in-depth, but
    // button handling does not — hence the parse-time filter.
    if p.dup {
        return None;
    }

    let now = clock.now();
    let topic = p.topic.as_str();

    // Z-Wave topics are under `zwave/` — try those first.
    if let Some(event) = parse_zwave_event(topology, topic, &p.payload, now) {
        return Some(event);
    }

    // Strip the `zigbee2mqtt/` prefix; everything we care about lives
    // under that namespace.
    let rest = topic.strip_prefix("zigbee2mqtt/")?;

    // Action topics → button press. The friendly name is everything
    // between the prefix and `/action`. The topology resolves the raw
    // z2m action string via the device's model descriptor.
    if let Some(name) = rest.strip_suffix("/action") {
        let payload_text = std::str::from_utf8(&p.payload).ok()?.trim_matches('"');
        let (_dev, button, gesture) = topology.resolve_button_event(name, payload_text)?;
        return Some(Event::ButtonPress {
            device: name.to_string(),
            button,
            gesture,
            ts: now,
        });
    }

    // With the wildcard subscription (`zigbee2mqtt/#`) we also receive
    // traffic we don't care about. Filter the obvious classes early so
    // we don't try to JSON-parse a bridge inventory blob every time it
    // flips.
    if rest.starts_with("bridge/")
        || rest.ends_with("/availability")
        || rest.ends_with("/set")
        || rest.ends_with("/get")
    {
        return None;
    }

    // State topic → motion sensor or group. The friendly name is the
    // entire `rest`. We branch by topology lookup.
    let name = rest;

    if topology.room_by_group_name(name).is_some() {
        // Group state. z2m aggregates member states; we read the
        // top-level `state` field.
        let value: serde_json::Value = serde_json::from_slice(&p.payload).ok()?;
        let state_str = value.get("state")?.as_str()?;
        let on = state_str.eq_ignore_ascii_case("ON");
        return Some(Event::GroupState {
            group: name.to_string(),
            on,
            ts: now,
        });
    }

    if topology.is_plug(name) {
        // Plug state. z2m publishes state + optional power reading.
        let value: serde_json::Value = serde_json::from_slice(&p.payload).ok()?;
        let state_str = value.get("state")?.as_str()?;
        let on = state_str.eq_ignore_ascii_case("ON");
        let power = value
            .get("power")
            .and_then(|v| v.as_f64());
        return Some(Event::PlugState {
            device: name.to_string(),
            on,
            power,
            ts: now,
        });
    }

    if topology.is_trv(name) {
        let value: serde_json::Value = serde_json::from_slice(&p.payload).ok()?;
        let local_temperature = value.get("local_temperature").and_then(|v| v.as_f64());
        let pi_heating_demand = value
            .get("pi_heating_demand")
            .and_then(|v| v.as_u64())
            .map(|n| n.min(100) as u8);
        let running_state = value
            .get("running_state")
            .and_then(|v| v.as_str())
            .map(String::from);
        let occupied_heating_setpoint = value
            .get("occupied_heating_setpoint")
            .and_then(|v| v.as_f64());
        let operating_mode = value
            .get("operating_mode")
            .and_then(|v| v.as_str())
            .map(String::from);
        let battery = value
            .get("battery")
            .and_then(|v| v.as_u64())
            .map(|n| n.min(100) as u8);
        return Some(Event::TrvState {
            device: name.to_string(),
            local_temperature,
            pi_heating_demand,
            running_state,
            occupied_heating_setpoint,
            operating_mode,
            battery,
            ts: now,
        });
    }

    if topology.is_wall_thermostat(name) {
        let value: serde_json::Value = serde_json::from_slice(&p.payload).ok()?;
        let relay_on = value
            .get("state")
            .and_then(|v| v.as_str())
            .map(|s| s.eq_ignore_ascii_case("ON"));
        let local_temperature = value.get("local_temperature").and_then(|v| v.as_f64());
        let operating_mode = value
            .get("operating_mode")
            .and_then(|v| v.as_str())
            .map(String::from);
        return Some(Event::WallThermostatState {
            device: name.to_string(),
            relay_on,
            local_temperature,
            operating_mode,
            ts: now,
        });
    }

    if !topology.rooms_for_motion(name).is_empty() {
        let value: serde_json::Value = serde_json::from_slice(&p.payload).ok()?;
        let occupied = value.get("occupancy")?.as_bool()?;
        let illuminance = value
            .get("illuminance")
            .and_then(|v| v.as_u64())
            .map(|n| n as u32);
        return Some(Event::Occupancy {
            sensor: name.to_string(),
            occupied,
            illuminance,
            ts: now,
        });
    }

    if topology.is_light(name) {
        // Individual bulb state: we don't target lights (groups are the
        // control surface) but do track actual state for the UI.
        let value: serde_json::Value = serde_json::from_slice(&p.payload).ok()?;
        let state_str = value.get("state")?.as_str()?;
        let on = state_str.eq_ignore_ascii_case("ON");
        let brightness = value
            .get("brightness")
            .and_then(|v| v.as_u64())
            .map(|n| n.min(255) as u8);
        let color_temp = value
            .get("color_temp")
            .and_then(|v| v.as_u64())
            .map(|n| n.min(u16::MAX as u64) as u16);
        let color_xy = value.get("color").and_then(|c| {
            let x = c.get("x")?.as_f64()?;
            let y = c.get("y")?.as_f64()?;
            Some((x, y))
        });
        return Some(Event::LightState {
            device: name.to_string(),
            on,
            brightness,
            color_temp,
            color_xy,
            ts: now,
        });
    }

    None
}

/// Parse a Z-Wave JS UI MQTT message into an [`Event`]. Z-Wave JS UI
/// publishes each value on its own topic with a wrapper payload:
/// `{"time":…,"value":<actual>,"nodeName":"…","nodeLocation":"…"}`.
///
/// We care about two topic shapes per Z-Wave plug:
///   - `zwave/<name>/switch_binary/endpoint_0/currentValue` → on/off
///   - `zwave/<name>/meter/endpoint_0/value/66049` → power (watts)
fn parse_zwave_event(
    topology: &Topology,
    topic: &str,
    payload: &[u8],
    now: Instant,
) -> Option<Event> {
    let rest = topic.strip_prefix("zwave/")?;

    // Binary switch state: zwave/<name>/switch_binary/endpoint_0/currentValue
    if let Some(name) = rest.strip_suffix("/switch_binary/endpoint_0/currentValue") {
        if !topology.is_zwave_plug(name) {
            return None;
        }
        let value: serde_json::Value = serde_json::from_slice(payload).ok()?;
        let on = value.get("value")?.as_bool()?;
        return Some(Event::PlugState {
            device: name.to_string(),
            on,
            power: None,
            ts: now,
        });
    }

    // Meter power reading: zwave/<name>/meter/endpoint_0/value/66049
    let meter_suffix = format!("/meter/endpoint_0/value/{}", codec::zwave_meter::POWER_W);
    if let Some(name) = rest.strip_suffix(&meter_suffix) {
        if !topology.is_zwave_plug(name) {
            return None;
        }
        let value: serde_json::Value = serde_json::from_slice(payload).ok()?;
        let watts = value.get("value")?.as_f64()?;
        // NAS-WR01ZE is known to send bogus large negative meter
        // reports; clamp to zero at parse time as first line of defense.
        // The controller also clamps uniformly in handle_plug_state.
        let watts = watts.max(0.0);
        return Some(Event::PlugPowerUpdate {
            device: name.to_string(),
            watts,
            ts: now,
        });
    }

    None
}
