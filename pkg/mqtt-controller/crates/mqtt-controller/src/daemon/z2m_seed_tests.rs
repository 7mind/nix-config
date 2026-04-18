//! Tests for `z2m_seed`. Exercise each event-builder against the JSON
//! shapes z2m publishes. `seed_z2m_state` itself talks to an external
//! WebSocket so it's covered by integration tests, not here.

use super::*;
use serde_json::json;

fn now() -> std::time::Instant {
    std::time::Instant::now()
}

#[test]
fn read_on_off_parses_on_and_off() {
    assert_eq!(read_on_off(&json!({"state": "ON"})), Some(true));
    assert_eq!(read_on_off(&json!({"state": "OFF"})), Some(false));
    assert_eq!(read_on_off(&json!({"state": "on"})), Some(true));
}

#[test]
fn read_on_off_returns_none_for_missing_or_bad_shape() {
    assert_eq!(read_on_off(&json!({})), None);
    assert_eq!(read_on_off(&json!({"state": 42})), None);
    assert_eq!(read_on_off(&json!({"other": "ON"})), None);
}

#[test]
fn group_event_extracts_on() {
    let ev = group_event("hue-lz-kitchen", &json!({"state": "ON"}), now()).unwrap();
    match ev {
        Event::GroupState { group, on, .. } => {
            assert_eq!(group, "hue-lz-kitchen");
            assert!(on);
        }
        other => panic!("expected GroupState, got {other:?}"),
    }
}

#[test]
fn plug_event_with_power() {
    let ev = plug_event(
        "z2m-p-printer",
        &json!({"state": "ON", "power": 120.5}),
        now(),
    )
    .unwrap();
    match ev {
        Event::PlugState { power, on, .. } => {
            assert!(on);
            assert!((power.unwrap() - 120.5).abs() < f64::EPSILON);
        }
        other => panic!("expected PlugState, got {other:?}"),
    }
}

#[test]
fn plug_event_without_power() {
    let ev = plug_event("plug", &json!({"state": "OFF"}), now()).unwrap();
    match ev {
        Event::PlugState { on, power, .. } => {
            assert!(!on);
            assert!(power.is_none());
        }
        other => panic!("expected PlugState, got {other:?}"),
    }
}

#[test]
fn light_event_brightness_and_color_temp() {
    let ev = light_event(
        "hue-l-kitchen",
        &json!({"state": "ON", "brightness": 200, "color_temp": 370}),
        now(),
    )
    .unwrap();
    match ev {
        Event::LightState {
            on,
            brightness,
            color_temp,
            ..
        } => {
            assert!(on);
            assert_eq!(brightness, Some(200));
            assert_eq!(color_temp, Some(370));
        }
        other => panic!("expected LightState, got {other:?}"),
    }
}

#[test]
fn light_event_color_xy() {
    let ev = light_event(
        "hue-l-kitchen",
        &json!({"state": "ON", "color": {"x": 0.45, "y": 0.41}}),
        now(),
    )
    .unwrap();
    match ev {
        Event::LightState { color_xy, .. } => {
            let (x, y) = color_xy.unwrap();
            assert!((x - 0.45).abs() < f64::EPSILON);
            assert!((y - 0.41).abs() < f64::EPSILON);
        }
        other => panic!("expected LightState, got {other:?}"),
    }
}

#[test]
fn trv_event_requires_at_least_one_field() {
    assert!(trv_event("trv", &json!({}), now()).is_none());
    let ev = trv_event("trv", &json!({"local_temperature": 20.5}), now()).unwrap();
    match ev {
        Event::TrvState {
            local_temperature, ..
        } => {
            assert_eq!(local_temperature, Some(20.5));
        }
        other => panic!("expected TrvState, got {other:?}"),
    }
}

#[test]
fn trv_event_full_payload() {
    let ev = trv_event(
        "trv",
        &json!({
            "local_temperature": 20.8,
            "pi_heating_demand": 60,
            "running_state": "heat",
            "occupied_heating_setpoint": 22.0,
            "operating_mode": "manual",
            "battery": 85
        }),
        now(),
    )
    .unwrap();
    match ev {
        Event::TrvState {
            local_temperature,
            pi_heating_demand,
            running_state,
            occupied_heating_setpoint,
            operating_mode,
            battery,
            ..
        } => {
            assert_eq!(local_temperature, Some(20.8));
            assert_eq!(pi_heating_demand, Some(60));
            assert_eq!(running_state.as_deref(), Some("heat"));
            assert_eq!(occupied_heating_setpoint, Some(22.0));
            assert_eq!(operating_mode.as_deref(), Some("manual"));
            assert_eq!(battery, Some(85));
        }
        other => panic!("expected TrvState, got {other:?}"),
    }
}

#[test]
fn wall_thermostat_event_returns_none_when_all_missing() {
    assert!(wall_thermostat_event("wt", &json!({}), now()).is_none());
}

#[test]
fn wall_thermostat_event_state_only() {
    let ev = wall_thermostat_event("wt", &json!({"state": "ON"}), now()).unwrap();
    match ev {
        Event::WallThermostatState { relay_on, .. } => {
            assert_eq!(relay_on, Some(true));
        }
        other => panic!("expected WallThermostatState, got {other:?}"),
    }
}

#[test]
fn occupancy_event_with_illuminance() {
    let ev = occupancy_event(
        "hue-ms-kitchen",
        &json!({"occupancy": true, "illuminance": 42}),
        now(),
    )
    .unwrap();
    match ev {
        Event::Occupancy {
            occupied,
            illuminance,
            ..
        } => {
            assert!(occupied);
            assert_eq!(illuminance, Some(42));
        }
        other => panic!("expected Occupancy, got {other:?}"),
    }
}

#[test]
fn occupancy_event_requires_occupancy_field() {
    assert!(occupancy_event("ms", &json!({}), now()).is_none());
}
