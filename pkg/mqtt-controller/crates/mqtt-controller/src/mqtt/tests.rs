//! Parser tests. The MQTT client itself is exercised by the
//! integration tests against rumqttd.

use rumqttc::{Publish, QoS};

use super::parse::parse_event;
use super::*;
use crate::config::catalog::PlugProtocol;
use crate::config::scenes::{Scene, SceneSchedule, Slot};
use crate::config::switch_model::{ActionMapping, Gesture, SwitchModel};
use crate::config::{
    Binding, CommonFields, Config, DeviceCatalogEntry, Defaults,
    Effect, Room, Trigger,
};
use crate::time::FakeClock;
use std::collections::BTreeMap;

fn clock() -> FakeClock {
    FakeClock::new(12)
}

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

/// Build a switch model descriptor for a Hue dimmer (4-button).
fn hue_dimmer_model() -> SwitchModel {
    SwitchModel {
        buttons: vec!["on".into(), "off".into(), "up".into(), "down".into()],
        z2m_action_map: BTreeMap::from([
            ("on_press_release".into(), ActionMapping { button: "on".into(), gesture: Gesture::Press }),
            ("off_press_release".into(), ActionMapping { button: "off".into(), gesture: Gesture::Press }),
            ("up_press_release".into(), ActionMapping { button: "up".into(), gesture: Gesture::Press }),
            ("up_hold".into(), ActionMapping { button: "up".into(), gesture: Gesture::Hold }),
            ("up_hold_release".into(), ActionMapping { button: "up".into(), gesture: Gesture::HoldRelease }),
            ("down_press_release".into(), ActionMapping { button: "down".into(), gesture: Gesture::Press }),
            ("down_hold".into(), ActionMapping { button: "down".into(), gesture: Gesture::Hold }),
            ("down_hold_release".into(), ActionMapping { button: "down".into(), gesture: Gesture::HoldRelease }),
        ]),
    }
}

fn small_topology() -> Arc<Topology> {
    let cfg = Config {
        name_by_address: BTreeMap::new(),
        devices: BTreeMap::from([
            (
                "hue-l-a".into(),
                DeviceCatalogEntry::Light(CommonFields {
                    ieee_address: "0xa".into(),
                    description: None,
                    options: BTreeMap::new(),
                }),
            ),
            (
                "hue-s-study".into(),
                DeviceCatalogEntry::Switch {
                    common: CommonFields {
                        ieee_address: "0x1".into(),
                        description: None,
                        options: BTreeMap::new(),
                    },
                    model: "hue-dimmer".into(),
                },
            ),
            (
                "hue-ms-study".into(),
                DeviceCatalogEntry::MotionSensor {
                    common: CommonFields {
                        ieee_address: "0x3".into(),
                        description: None,
                        options: BTreeMap::new(),
                    },
                    occupancy_timeout_seconds: 60,
                    max_illuminance: None,
                },
            ),
            (
                "z2m-p-printer".into(),
                DeviceCatalogEntry::Plug {
                    common: CommonFields {
                        ieee_address: "0xf".into(),
                        description: None,
                        options: BTreeMap::new(),
                    },
                    variant: "sonoff-power".into(),
                    capabilities: vec!["on-off".into(), "power".into()],
                    protocol: PlugProtocol::Zigbee,
                    node_id: None,
                },
            ),
            (
                "zneo-p-attic-desk".into(),
                DeviceCatalogEntry::Plug {
                    common: CommonFields {
                        ieee_address: "zwave:6".into(),
                        description: None,
                        options: BTreeMap::new(),
                    },
                    variant: "neo-nas-wr01ze".into(),
                    capabilities: vec!["on-off".into(), "power".into()],
                    protocol: PlugProtocol::Zwave,
                    node_id: Some(6),
                },
            ),
        ]),
        switch_models: BTreeMap::from([
            ("hue-dimmer".into(), hue_dimmer_model()),
        ]),
        rooms: vec![Room {
            name: "study".into(),
            group_name: "hue-lz-study".into(),
            id: 1,
            members: vec!["hue-l-a/11".into()],
            parent: None,
            motion_sensors: vec!["hue-ms-study".into()],
            scenes: day_scenes(),
            off_transition_seconds: 0.8,
            motion_off_cooldown_seconds: 0,
        }],
        bindings: vec![
            Binding {
                name: "study-on".into(),
                trigger: Trigger::Button {
                    device: "hue-s-study".into(),
                    button: "on".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::SceneToggleCycle {
                    room: "study".into(),
                },
            },
            Binding {
                name: "study-off".into(),
                trigger: Trigger::Button {
                    device: "hue-s-study".into(),
                    button: "off".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::TurnOffRoom {
                    room: "study".into(),
                },
            },
            Binding {
                name: "printer-kill".into(),
                trigger: Trigger::PowerBelow {
                    device: "z2m-p-printer".into(),
                    watts: 5.0,
                    for_seconds: 300,
                },
                effect: Effect::TurnOff {
                    target: "z2m-p-printer".into(),
                },
            },
        ],
        defaults: Defaults::default(),
        heating: None,
        location: None,
    };
    Arc::new(Topology::build(&cfg).unwrap())
}

fn publish(topic: &str, payload: &str) -> Publish {
    Publish::new(topic, QoS::AtLeastOnce, payload.as_bytes().to_vec())
}

#[test]
fn parse_button_press() {
    let topo = small_topology();
    let p = publish("zigbee2mqtt/hue-s-study/action", "on_press_release");
    let event = parse_event(&topo, &p, &clock()).unwrap();
    match event {
        Event::ButtonPress {
            device,
            button,
            gesture,
            ..
        } => {
            assert_eq!(device, "hue-s-study");
            assert_eq!(button, "on");
            assert_eq!(gesture, Gesture::Press);
        }
        other => panic!("expected ButtonPress, got {other:?}"),
    }
}

#[test]
fn parse_button_hold() {
    let topo = small_topology();
    let p = publish("zigbee2mqtt/hue-s-study/action", "up_hold");
    let event = parse_event(&topo, &p, &clock()).unwrap();
    match event {
        Event::ButtonPress {
            device,
            button,
            gesture,
            ..
        } => {
            assert_eq!(device, "hue-s-study");
            assert_eq!(button, "up");
            assert_eq!(gesture, Gesture::Hold);
        }
        other => panic!("expected ButtonPress Hold, got {other:?}"),
    }
}

#[test]
fn parse_group_state_on() {
    let topo = small_topology();
    let p = publish(
        "zigbee2mqtt/hue-lz-study",
        r#"{"state":"ON","brightness":254}"#,
    );
    let event = parse_event(&topo, &p, &clock()).unwrap();
    match event {
        Event::GroupState { group, on, .. } => {
            assert_eq!(group, "hue-lz-study");
            assert!(on);
        }
        other => panic!("expected GroupState, got {other:?}"),
    }
}

#[test]
fn parse_group_state_off() {
    let topo = small_topology();
    let p = publish("zigbee2mqtt/hue-lz-study", r#"{"state":"OFF"}"#);
    let event = parse_event(&topo, &p, &clock()).unwrap();
    match event {
        Event::GroupState { on: false, .. } => {}
        other => panic!("expected GroupState off, got {other:?}"),
    }
}

#[test]
fn parse_motion_with_illuminance() {
    let topo = small_topology();
    let p = publish(
        "zigbee2mqtt/hue-ms-study",
        r#"{"occupancy":true,"illuminance":42,"battery":97}"#,
    );
    let event = parse_event(&topo, &p, &clock()).unwrap();
    match event {
        Event::Occupancy {
            sensor,
            occupied,
            illuminance,
            ..
        } => {
            assert_eq!(sensor, "hue-ms-study");
            assert!(occupied);
            assert_eq!(illuminance, Some(42));
        }
        other => panic!("expected Occupancy, got {other:?}"),
    }
}

#[test]
fn parse_motion_without_illuminance() {
    let topo = small_topology();
    let p = publish("zigbee2mqtt/hue-ms-study", r#"{"occupancy":false}"#);
    let event = parse_event(&topo, &p, &clock()).unwrap();
    match event {
        Event::Occupancy {
            occupied: false,
            illuminance: None,
            ..
        } => {}
        other => panic!("expected Occupancy off, got {other:?}"),
    }
}

#[test]
fn unknown_topic_returns_none() {
    let topo = small_topology();
    let p = publish("zigbee2mqtt/hue-l-other/action", "on_press_release");
    assert!(parse_event(&topo, &p, &clock()).is_none());
}

#[test]
fn malformed_payload_returns_none() {
    let topo = small_topology();
    let p = publish("zigbee2mqtt/hue-lz-study", "not json");
    assert!(parse_event(&topo, &p, &clock()).is_none());
}

#[test]
fn unrecognized_action_string_returns_none() {
    let topo = small_topology();
    let p = publish("zigbee2mqtt/hue-s-study/action", "long_press");
    assert!(parse_event(&topo, &p, &clock()).is_none());
}

#[test]
fn parse_plug_state_on_with_power() {
    let topo = small_topology();
    let p = publish(
        "zigbee2mqtt/z2m-p-printer",
        r#"{"state":"ON","power":120.5,"energy":42.1}"#,
    );
    let event = parse_event(&topo, &p, &clock()).unwrap();
    match event {
        Event::PlugState {
            device,
            on,
            power,
            ..
        } => {
            assert_eq!(device, "z2m-p-printer");
            assert!(on);
            assert!((power.unwrap() - 120.5).abs() < f64::EPSILON);
        }
        other => panic!("expected PlugState, got {other:?}"),
    }
}

#[test]
fn parse_plug_state_off_no_power() {
    let topo = small_topology();
    let p = publish(
        "zigbee2mqtt/z2m-p-printer",
        r#"{"state":"OFF"}"#,
    );
    let event = parse_event(&topo, &p, &clock()).unwrap();
    match event {
        Event::PlugState {
            on,
            power,
            ..
        } => {
            assert!(!on);
            assert!(power.is_none());
        }
        other => panic!("expected PlugState off, got {other:?}"),
    }
}

#[test]
fn plug_state_takes_priority_over_unknown() {
    let topo = small_topology();
    // Even though z2m-p-printer is not a group or sensor, it should
    // parse as PlugState, not return None.
    let p = publish(
        "zigbee2mqtt/z2m-p-printer",
        r#"{"state":"ON","power":0.5}"#,
    );
    assert!(matches!(
        parse_event(&topo, &p, &clock()),
        Some(Event::PlugState { .. })
    ));
}

// ---- Z-Wave plug tests ------------------------------------------------

#[test]
fn parse_zwave_switch_on() {
    let topo = small_topology();
    let p = publish(
        "zwave/zneo-p-attic-desk/switch_binary/endpoint_0/currentValue",
        r#"{"time":1775507352385,"value":true,"nodeName":"zneo-p-attic-desk","nodeLocation":""}"#,
    );
    let event = parse_event(&topo, &p, &clock()).unwrap();
    match event {
        Event::PlugState { device, on, power, .. } => {
            assert_eq!(device, "zneo-p-attic-desk");
            assert!(on);
            assert!(power.is_none());
        }
        other => panic!("expected PlugState, got {other:?}"),
    }
}

#[test]
fn parse_zwave_switch_off() {
    let topo = small_topology();
    let p = publish(
        "zwave/zneo-p-attic-desk/switch_binary/endpoint_0/currentValue",
        r#"{"time":1775507352385,"value":false,"nodeName":"zneo-p-attic-desk","nodeLocation":""}"#,
    );
    let event = parse_event(&topo, &p, &clock()).unwrap();
    match event {
        Event::PlugState { on, .. } => assert!(!on),
        other => panic!("expected PlugState off, got {other:?}"),
    }
}

#[test]
fn parse_zwave_meter_power() {
    let topo = small_topology();
    let p = publish(
        "zwave/zneo-p-attic-desk/meter/endpoint_0/value/66049",
        r#"{"time":1775507242082,"value":42.5,"nodeName":"zneo-p-attic-desk","nodeLocation":""}"#,
    );
    let event = parse_event(&topo, &p, &clock()).unwrap();
    match event {
        Event::PlugPowerUpdate { device, watts, .. } => {
            assert_eq!(device, "zneo-p-attic-desk");
            assert!((watts - 42.5).abs() < f64::EPSILON);
        }
        other => panic!("expected PlugPowerUpdate, got {other:?}"),
    }
}

#[test]
fn parse_zwave_meter_negative_clamped_to_zero() {
    let topo = small_topology();
    // NAS-WR01ZE sends bogus negative values occasionally.
    let p = publish(
        "zwave/zneo-p-attic-desk/meter/endpoint_0/value/66049",
        r#"{"time":1775507242082,"value":-12345.6,"nodeName":"zneo-p-attic-desk","nodeLocation":""}"#,
    );
    let event = parse_event(&topo, &p, &clock()).unwrap();
    match event {
        Event::PlugPowerUpdate { watts, .. } => {
            assert_eq!(watts, 0.0);
        }
        other => panic!("expected PlugPowerUpdate, got {other:?}"),
    }
}

#[test]
fn zwave_unknown_device_returns_none() {
    let topo = small_topology();
    let p = publish(
        "zwave/unknown-device/switch_binary/endpoint_0/currentValue",
        r#"{"time":0,"value":true,"nodeName":"","nodeLocation":""}"#,
    );
    assert!(parse_event(&topo, &p, &clock()).is_none());
}

#[test]
fn zwave_unrelated_topic_returns_none() {
    let topo = small_topology();
    let p = publish(
        "zwave/zneo-p-attic-desk/configuration/endpoint_0/LED_Indicator",
        r#"{"time":0,"value":1,"nodeName":"","nodeLocation":""}"#,
    );
    assert!(parse_event(&topo, &p, &clock()).is_none());
}
