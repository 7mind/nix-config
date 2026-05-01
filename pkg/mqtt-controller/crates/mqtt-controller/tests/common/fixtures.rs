//! Hand-rolled JSON fixture used by the end-to-end tests. Mirrors the
//! production kitchen layout (parent + 3 sub-zones, each on a separate
//! tap button) so the kitchen-all bug regression has somewhere to live.

use std::collections::BTreeMap;

use mqtt_controller::config::scenes::{Scene, SceneSchedule, Slot};
use mqtt_controller::config::switch_model::{ActionMapping, Gesture, SwitchModel};
use mqtt_controller::config::{
    Binding, CommonFields, Config, DeviceCatalogEntry, Defaults, Effect, Room, Trigger,
};

fn day_scenes(ids: Vec<u8>) -> SceneSchedule {
    SceneSchedule {
        scenes: ids
            .iter()
            .map(|&id| Scene {
                id,
                name: format!("scene-{id}"),
                state: "ON".into(),
                brightness: None,
                color_temp: None,
                transition: 0.0,
            })
            .collect(),
        slots: BTreeMap::from([(
            "day".into(),
            Slot {
                from: mqtt_controller::config::TimeExpr::Fixed { minute_of_day: 0 },
                to: mqtt_controller::config::TimeExpr::Fixed { minute_of_day: 1440 },
                scene_ids: ids,
            },
        )]),
    }
}

fn light(ieee: &str) -> DeviceCatalogEntry {
    DeviceCatalogEntry::Light(CommonFields {
        ieee_address: ieee.into(),
        description: None,
        options: BTreeMap::new(),
    })
}

fn motion_sensor_dev(ieee: &str) -> DeviceCatalogEntry {
    DeviceCatalogEntry::MotionSensor {
        common: CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::new(),
        },
        occupancy_timeout_seconds: 60,
        max_illuminance: None,
    }
}

fn switch_dev(ieee: &str, model: &str) -> DeviceCatalogEntry {
    DeviceCatalogEntry::Switch {
        common: CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::new(),
        },
        model: model.into(),
    }
}

fn tap_model() -> SwitchModel {
    SwitchModel {
        buttons: vec!["1".into(), "2".into(), "3".into(), "4".into()],
        z2m_action_map: BTreeMap::from([
            ("press_1".into(), ActionMapping { button: "1".into(), gesture: Gesture::Press }),
            ("press_2".into(), ActionMapping { button: "2".into(), gesture: Gesture::Press }),
            ("press_3".into(), ActionMapping { button: "3".into(), gesture: Gesture::Press }),
            ("press_4".into(), ActionMapping { button: "4".into(), gesture: Gesture::Press }),
        ]),
    }
}

fn scene_toggle_cycle_binding(name: &str, device: &str, button: &str, room: &str) -> Binding {
    button_binding(name, device, button, Gesture::Press,
        Effect::SceneToggleCycle { room: room.into() })
}

/// Build a kitchen-style room with the standard 3-scene day schedule
/// and zero off-transition / motion-cooldown.
fn kitchen_room(
    name: &str,
    group: &str,
    id: u8,
    members: &[&str],
    parent: Option<&str>,
) -> Room {
    Room {
        name: name.into(),
        group_name: group.into(),
        id,
        members: members.iter().map(|m| (*m).into()).collect(),
        parent: parent.map(String::from),
        motion_sensors: vec![],
        scenes: day_scenes(vec![1, 2, 3]),
        off_transition_seconds: 0.8,
        motion_off_cooldown_seconds: 0,
        motion_mode: Default::default(),
    }
}

/// Minimal kitchen layout:
///   * `kitchen-cooker` — child of `kitchen-all`, tap button 2
///   * `kitchen-dining` — child of `kitchen-all`, tap button 3
///   * `kitchen-all`    — parent, tap button 1
pub fn kitchen_config() -> Config {
    Config {
        name_by_address: BTreeMap::new(),
        devices: BTreeMap::from([
            ("hue-l-cooker".into(), light("0xa")),
            ("hue-l-dining".into(), light("0xb")),
            ("hue-l-empty".into(), light("0xc")),
            ("hue-ts-foo".into(), switch_dev("0x1", "test-tap")),
        ]),
        switch_models: BTreeMap::from([
            ("test-tap".into(), tap_model()),
        ]),
        rooms: vec![
            kitchen_room("kitchen-cooker", "hue-lz-kitchen-cooker", 1,
                &["hue-l-cooker/11"], Some("kitchen-all")),
            kitchen_room("kitchen-dining", "hue-lz-kitchen-dining", 2,
                &["hue-l-dining/11"], Some("kitchen-all")),
            kitchen_room("kitchen-all", "hue-lz-kitchen-all", 3,
                &["hue-l-cooker/11", "hue-l-dining/11", "hue-l-empty/11"], None),
        ],
        bindings: vec![
            scene_toggle_cycle_binding("cooker-tap", "hue-ts-foo", "2", "kitchen-cooker"),
            scene_toggle_cycle_binding("dining-tap", "hue-ts-foo", "3", "kitchen-dining"),
            scene_toggle_cycle_binding("all-tap", "hue-ts-foo", "1", "kitchen-all"),
        ],
        defaults: Defaults::default(),
        heating: None,
        location: None,
        audit_log: None,
    }
}

/// Sonoff switch model with hardware double-tap support.
/// Maps "single_button_1" → Press and "double_button_1" → DoubleTap.
fn sonoff_model() -> SwitchModel {
    SwitchModel {
        buttons: vec!["1".into()],
        z2m_action_map: BTreeMap::from([
            ("single_button_1".into(), ActionMapping { button: "1".into(), gesture: Gesture::Press }),
            ("double_button_1".into(), ActionMapping { button: "1".into(), gesture: Gesture::DoubleTap }),
        ]),
    }
}

/// Build a button-press binding with arbitrary effect.
fn button_binding(name: &str, device: &str, button: &str, gesture: Gesture, effect: Effect) -> Binding {
    Binding {
        name: name.into(),
        trigger: Trigger::Button {
            device: device.into(),
            button: button.into(),
            gesture,
        },
        effect,
    }
}

/// Bedroom with a Sonoff switch using cycleOnDoubleTap pattern:
///   * Press on button "1"     → SceneToggle for "bedroom"
///   * DoubleTap on button "1" → SceneCycle for "bedroom"
///
/// Used for the double-tap suppression regression test.
pub fn kitchen_with_sonoff_config() -> Config {
    Config {
        name_by_address: BTreeMap::new(),
        devices: BTreeMap::from([
            ("hue-l-bedroom".into(), light("0xe")),
            ("sonoff-ts-bedroom".into(), switch_dev("0x2", "test-sonoff")),
        ]),
        switch_models: BTreeMap::from([
            ("test-sonoff".into(), sonoff_model()),
        ]),
        rooms: vec![
            kitchen_room("bedroom", "hue-lz-bedroom", 20, &["hue-l-bedroom/11"], None),
        ],
        bindings: vec![
            button_binding("bedroom-toggle", "sonoff-ts-bedroom", "1", Gesture::Press,
                Effect::SceneToggle { room: "bedroom".into() }),
            button_binding("bedroom-cycle", "sonoff-ts-bedroom", "1", Gesture::DoubleTap,
                Effect::SceneCycle { room: "bedroom".into() }),
        ],
        defaults: Defaults::default(),
        heating: None,
        location: None,
        audit_log: None,
    }
}

/// Kitchen layout with a motion sensor on the cooker zone.
/// Same parent/child structure as `kitchen_config()` but adds motion
/// sensor `hue-ms-kitchen` bound to `kitchen-cooker`.
pub fn kitchen_with_motion_config() -> Config {
    let mut cfg = kitchen_config();
    cfg.devices.insert("hue-ms-kitchen".into(), motion_sensor_dev("0xd"));
    let cooker = cfg.rooms.iter_mut()
        .find(|r| r.name == "kitchen-cooker")
        .expect("kitchen-cooker room");
    cooker.motion_sensors.push("hue-ms-kitchen".into());
    cfg
}
