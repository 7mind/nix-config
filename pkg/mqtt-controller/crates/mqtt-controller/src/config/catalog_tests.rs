//! Tests for `catalog`. Split out so `catalog.rs` stays focused on
//! production code. See `catalog.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;

#[test]
fn deserialize_motion_sensor_with_defaults() {
    let json = r#"{
        "kind": "motion-sensor",
        "ieee_address": "0xaa"
    }"#;
    let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
    match entry {
        DeviceCatalogEntry::MotionSensor {
            occupancy_timeout_seconds,
            max_illuminance,
            ..
        } => {
            assert_eq!(occupancy_timeout_seconds, 60);
            assert_eq!(max_illuminance, None);
        }
        other => panic!("expected MotionSensor, got {other:?}"),
    }
}

#[test]
fn deserialize_motion_sensor_with_overrides() {
    let json = r#"{
        "kind": "motion-sensor",
        "ieee_address": "0xaa",
        "occupancy_timeout_seconds": 180,
        "max_illuminance": 25
    }"#;
    let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
    match entry {
        DeviceCatalogEntry::MotionSensor {
            occupancy_timeout_seconds,
            max_illuminance,
            ..
        } => {
            assert_eq!(occupancy_timeout_seconds, 180);
            assert_eq!(max_illuminance, Some(25));
        }
        other => panic!("expected MotionSensor, got {other:?}"),
    }
}

#[test]
fn deserialize_switch_with_model() {
    let json = r#"{"kind":"switch","ieee_address":"0x2","model":"hue-dimmer-v2"}"#;
    let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
    assert!(entry.is_switch());
    assert_eq!(entry.switch_model(), Some("hue-dimmer-v2"));
}

#[test]
fn options_carry_arbitrary_json() {
    let json = r#"{
        "kind": "motion-sensor",
        "ieee_address": "0xaa",
        "options": {
            "occupancy_timeout": 60,
            "motion_sensitivity": "high",
            "led_indication": false
        }
    }"#;
    let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
    let opts = entry.options();
    assert_eq!(opts.len(), 3);
    assert_eq!(opts.get("motion_sensitivity").unwrap(), &serde_json::json!("high"));
}

#[test]
fn unknown_field_is_rejected() {
    let json = r#"{
        "kind": "switch",
        "ieee_address": "0x2",
        "model": "hue-dimmer-v2",
        "ghost_field": 42
    }"#;
    let result: Result<DeviceCatalogEntry, _> = serde_json::from_str(json);
    assert!(
        result.is_err(),
        "deny_unknown_fields should reject ghost_field"
    );
}

#[test]
fn deserialize_plug_with_capabilities() {
    let json = r#"{
        "kind": "plug",
        "ieee_address": "0xbb",
        "variant": "sonoff-power",
        "capabilities": ["on-off", "power", "energy"]
    }"#;
    let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
    assert!(entry.is_plug());
    assert!(!entry.is_zwave_plug());
    assert_eq!(entry.plug_protocol(), Some(PlugProtocol::Zigbee));
    assert!(entry.has_capability("power"));
    assert!(entry.has_capability("on-off"));
    assert!(!entry.has_capability("voltage"));
    match entry {
        DeviceCatalogEntry::Plug { variant, capabilities, protocol, node_id, .. } => {
            assert_eq!(variant, "sonoff-power");
            assert_eq!(capabilities, vec!["on-off", "power", "energy"]);
            assert_eq!(protocol, PlugProtocol::Zigbee);
            assert_eq!(node_id, None);
        }
        other => panic!("expected Plug, got {other:?}"),
    }
}

#[test]
fn deserialize_plug_basic_no_power() {
    let json = r#"{
        "kind": "plug",
        "ieee_address": "0xcc",
        "variant": "sonoff-basic",
        "capabilities": ["on-off"]
    }"#;
    let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
    assert!(entry.is_plug());
    assert!(!entry.has_capability("power"));
}

#[test]
fn plug_is_not_runtime_input() {
    let json = r#"{
        "kind": "plug",
        "ieee_address": "0xdd",
        "variant": "sonoff-power",
        "capabilities": ["on-off", "power"]
    }"#;
    let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
    assert!(!entry.is_switch());
}

#[test]
fn deserialize_zwave_plug() {
    let json = r#"{
        "kind": "plug",
        "ieee_address": "zwave:6",
        "variant": "neo-nas-wr01ze",
        "capabilities": ["on-off", "power"],
        "protocol": "zwave",
        "node_id": 6
    }"#;
    let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
    assert!(entry.is_plug());
    assert!(entry.is_zwave_plug());
    assert_eq!(entry.plug_protocol(), Some(PlugProtocol::Zwave));
    assert_eq!(entry.zwave_node_id(), Some(6));
    assert!(entry.has_capability("power"));
}

#[test]
fn zwave_plug_without_node_id() {
    let json = r#"{
        "kind": "plug",
        "ieee_address": "zwave:?",
        "variant": "neo-nas-wr01ze",
        "capabilities": ["on-off"],
        "protocol": "zwave"
    }"#;
    let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
    assert!(entry.is_zwave_plug());
    assert_eq!(entry.zwave_node_id(), None);
}

#[test]
fn classifier_helpers() {
    let switch = DeviceCatalogEntry::Switch {
        common: CommonFields {
            ieee_address: "0x1".into(),
            description: None,
            options: BTreeMap::new(),
        },
        model: "hue-dimmer-v2".into(),
    };
    assert!(switch.is_switch());
    assert_eq!(switch.switch_model(), Some("hue-dimmer-v2"));

    let light = DeviceCatalogEntry::Light(CommonFields {
        ieee_address: "0x2".into(),
        description: None,
        options: BTreeMap::new(),
    });
    assert!(!light.is_switch());

    let ms = DeviceCatalogEntry::MotionSensor {
        common: CommonFields {
            ieee_address: "0x3".into(),
            description: None,
            options: BTreeMap::new(),
        },
        occupancy_timeout_seconds: 60,
        max_illuminance: None,
    };
    assert!(ms.is_motion_sensor());
}
