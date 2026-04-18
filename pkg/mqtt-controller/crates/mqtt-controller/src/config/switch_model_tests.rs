//! Tests for `switch_model`. Split out so `switch_model.rs` stays focused on
//! production code. See `switch_model.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;

#[test]
fn deserialize_hue_dimmer_model() {
    let json = r#"{
        "buttons": ["on", "off", "up", "down"],
        "z2m_action_map": {
            "on_press_release": { "button": "on", "gesture": "press" },
            "off_press_release": { "button": "off", "gesture": "press" },
            "up_press_release": { "button": "up", "gesture": "press" },
            "up_hold": { "button": "up", "gesture": "hold" },
            "up_hold_release": { "button": "up", "gesture": "hold_release" },
            "down_press_release": { "button": "down", "gesture": "press" },
            "down_hold": { "button": "down", "gesture": "hold" },
            "down_hold_release": { "button": "down", "gesture": "hold_release" }
        }
    }"#;
    let model: SwitchModel = serde_json::from_str(json).unwrap();
    assert_eq!(model.buttons.len(), 4);
    let mapping = model.resolve("on_press_release").unwrap();
    assert_eq!(mapping.button, "on");
    assert_eq!(mapping.gesture, Gesture::Press);
    assert!(!model.has_hardware_double_tap());
}

#[test]
fn deserialize_sonoff_orb_model() {
    let json = r#"{
        "buttons": ["1", "2", "3", "4"],
        "z2m_action_map": {
            "single_button_1": { "button": "1", "gesture": "press" },
            "single_button_2": { "button": "2", "gesture": "press" },
            "double_button_1": { "button": "1", "gesture": "double_tap" },
            "double_button_2": { "button": "2", "gesture": "double_tap" }
        }
    }"#;
    let model: SwitchModel = serde_json::from_str(json).unwrap();
    assert!(model.has_hardware_double_tap());
    let mapping = model.resolve("double_button_1").unwrap();
    assert_eq!(mapping.button, "1");
    assert_eq!(mapping.gesture, Gesture::DoubleTap);
}

#[test]
fn unknown_action_returns_none() {
    let json = r#"{
        "buttons": ["1"],
        "z2m_action_map": {
            "press_1": { "button": "1", "gesture": "press" }
        }
    }"#;
    let model: SwitchModel = serde_json::from_str(json).unwrap();
    assert!(model.resolve("unknown_action").is_none());
}

#[test]
fn gesture_roundtrip() {
    for gesture in [Gesture::Press, Gesture::Hold, Gesture::HoldRelease, Gesture::DoubleTap, Gesture::SoftDoubleTap] {
        let json = serde_json::to_string(&gesture).unwrap();
        let back: Gesture = serde_json::from_str(&json).unwrap();
        assert_eq!(gesture, back);
    }
}
