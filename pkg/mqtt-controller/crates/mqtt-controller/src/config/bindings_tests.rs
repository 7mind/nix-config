//! Tests for `bindings`. Split out so `bindings.rs` stays focused on
//! production code. See `bindings.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;

#[test]
fn deserialize_button_scene_cycle() {
    let json = r#"{
        "name": "kitchen-on",
        "trigger": { "kind": "button", "device": "hue-s-kitchen", "button": "on", "gesture": "press" },
        "effect": { "kind": "scene_cycle", "room": "kitchen-cooker" }
    }"#;
    let binding: Binding = serde_json::from_str(json).unwrap();
    assert_eq!(binding.name, "kitchen-on");
    assert_eq!(binding.trigger.device(), Some("hue-s-kitchen"));
    assert_eq!(binding.effect.room(), Some("kitchen-cooker"));
    match &binding.trigger {
        Trigger::Button { button, gesture, .. } => {
            assert_eq!(button, "on");
            assert_eq!(*gesture, Gesture::Press);
        }
        other => panic!("expected Button, got {other:?}"),
    }
}

#[test]
fn deserialize_button_toggle_plug() {
    let json = r#"{
        "name": "printer-toggle",
        "trigger": { "kind": "button", "device": "hue-ts-office", "button": "3", "gesture": "press" },
        "effect": { "kind": "toggle", "target": "z2m-p-printer" }
    }"#;
    let binding: Binding = serde_json::from_str(json).unwrap();
    assert_eq!(binding.effect.target(), Some("z2m-p-printer"));
}

#[test]
fn deserialize_power_below() {
    let json = r#"{
        "name": "printer-kill",
        "trigger": { "kind": "power_below", "device": "z2m-p-printer", "watts": 5.0, "for_seconds": 300 },
        "effect": { "kind": "turn_off", "target": "z2m-p-printer" }
    }"#;
    let binding: Binding = serde_json::from_str(json).unwrap();
    match &binding.trigger {
        Trigger::PowerBelow { watts, for_seconds, .. } => {
            assert!((watts - 5.0).abs() < f64::EPSILON);
            assert_eq!(*for_seconds, 300);
        }
        other => panic!("expected PowerBelow, got {other:?}"),
    }
}

#[test]
fn deserialize_brightness_step() {
    let json = r#"{
        "name": "kitchen-up",
        "trigger": { "kind": "button", "device": "hue-s-kitchen", "button": "up", "gesture": "press" },
        "effect": { "kind": "brightness_step", "room": "kitchen-cooker", "step": 25, "transition": 0.2 }
    }"#;
    let binding: Binding = serde_json::from_str(json).unwrap();
    match &binding.effect {
        Effect::BrightnessStep { step, transition, .. } => {
            assert_eq!(*step, 25);
            assert!((transition - 0.2).abs() < f64::EPSILON);
        }
        other => panic!("expected BrightnessStep, got {other:?}"),
    }
}

#[test]
fn deserialize_scene_toggle() {
    let json = r#"{
        "name": "bedroom-toggle",
        "trigger": { "kind": "button", "device": "sonoff-ts-foo", "button": "1", "gesture": "press" },
        "effect": { "kind": "scene_toggle", "room": "bedroom" }
    }"#;
    let binding: Binding = serde_json::from_str(json).unwrap();
    match &binding.effect {
        Effect::SceneToggle { room } => assert_eq!(room, "bedroom"),
        other => panic!("expected SceneToggle, got {other:?}"),
    }
}

#[test]
fn deserialize_scene_toggle_cycle() {
    let json = r#"{
        "name": "tap-2-kitchen",
        "trigger": { "kind": "button", "device": "hue-ts-entrance", "button": "2", "gesture": "press" },
        "effect": { "kind": "scene_toggle_cycle", "room": "kitchen-cooker" }
    }"#;
    let binding: Binding = serde_json::from_str(json).unwrap();
    match &binding.effect {
        Effect::SceneToggleCycle { room } => assert_eq!(room, "kitchen-cooker"),
        other => panic!("expected SceneToggleCycle, got {other:?}"),
    }
}

#[test]
fn deserialize_soft_double_tap() {
    let json = r#"{
        "name": "kitchen-dbl",
        "trigger": { "kind": "button", "device": "hue-s-kitchen", "button": "on", "gesture": "soft_double_tap" },
        "effect": { "kind": "turn_off_all_zones" }
    }"#;
    let binding: Binding = serde_json::from_str(json).unwrap();
    match &binding.trigger {
        Trigger::Button { gesture, .. } => assert_eq!(*gesture, Gesture::SoftDoubleTap),
        other => panic!("expected Button, got {other:?}"),
    }
}

#[test]
fn deserialize_toggle_with_confirm_off() {
    let json = r#"{
        "name": "ws-toggle",
        "trigger": { "kind": "button", "device": "sonoff-ts-ws", "button": "1", "gesture": "press" },
        "effect": { "kind": "toggle", "target": "sonoff-p-ws", "confirm_off_seconds": 1.0 }
    }"#;
    let binding: Binding = serde_json::from_str(json).unwrap();
    assert_eq!(binding.effect.confirm_off_seconds(), Some(1.0));
}

#[test]
fn unknown_trigger_kind_rejected() {
    let json = r#"{
        "name": "bad",
        "trigger": { "kind": "explosion", "device": "x" },
        "effect": { "kind": "toggle", "target": "y" }
    }"#;
    assert!(serde_json::from_str::<Binding>(json).is_err());
}

#[test]
fn unknown_effect_kind_rejected() {
    let json = r#"{
        "name": "bad",
        "trigger": { "kind": "button", "device": "x", "button": "1", "gesture": "press" },
        "effect": { "kind": "explode", "target": "y" }
    }"#;
    assert!(serde_json::from_str::<Binding>(json).is_err());
}

#[test]
fn effect_room_accessor() {
    let e = Effect::SceneCycle { room: "kitchen".into() };
    assert_eq!(e.room(), Some("kitchen"));
    assert_eq!(e.target(), None);

    let e = Effect::SceneToggle { room: "bedroom".into() };
    assert_eq!(e.room(), Some("bedroom"));
    assert_eq!(e.target(), None);

    let e = Effect::Toggle { target: "plug".into(), confirm_off_seconds: None };
    assert_eq!(e.room(), None);
    assert_eq!(e.target(), Some("plug"));

    assert_eq!(Effect::TurnOffAllZones.room(), None);
    assert_eq!(Effect::TurnOffAllZones.target(), None);
}
