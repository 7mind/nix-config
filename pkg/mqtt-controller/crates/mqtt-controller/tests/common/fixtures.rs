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

fn dimmer_model() -> SwitchModel {
    SwitchModel {
        buttons: vec!["on".into(), "off".into(), "up".into(), "down".into()],
        z2m_action_map: BTreeMap::from([
            ("on_press_release".into(), ActionMapping { button: "on".into(), gesture: Gesture::Press }),
            ("off_press_release".into(), ActionMapping { button: "off".into(), gesture: Gesture::Press }),
            ("up_press_release".into(), ActionMapping { button: "up".into(), gesture: Gesture::Press }),
            ("down_press_release".into(), ActionMapping { button: "down".into(), gesture: Gesture::Press }),
            ("up_hold".into(), ActionMapping { button: "up".into(), gesture: Gesture::Hold }),
            ("up_hold_release".into(), ActionMapping { button: "up".into(), gesture: Gesture::HoldRelease }),
            ("down_hold".into(), ActionMapping { button: "down".into(), gesture: Gesture::Hold }),
            ("down_hold_release".into(), ActionMapping { button: "down".into(), gesture: Gesture::HoldRelease }),
        ]),
    }
}

fn scene_toggle_cycle_binding(name: &str, device: &str, button: &str, room: &str) -> Binding {
    Binding {
        name: name.into(),
        trigger: Trigger::Button {
            device: device.into(),
            button: button.into(),
            gesture: Gesture::Press,
        },
        effect: Effect::SceneToggleCycle { room: room.into() },
    }
}

fn scene_cycle_binding(name: &str, device: &str, button: &str, room: &str) -> Binding {
    Binding {
        name: name.into(),
        trigger: Trigger::Button {
            device: device.into(),
            button: button.into(),
            gesture: Gesture::Press,
        },
        effect: Effect::SceneCycle { room: room.into() },
    }
}

fn turn_off_room_binding(name: &str, device: &str, button: &str, room: &str) -> Binding {
    Binding {
        name: name.into(),
        trigger: Trigger::Button {
            device: device.into(),
            button: button.into(),
            gesture: Gesture::Press,
        },
        effect: Effect::TurnOffRoom { room: room.into() },
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
            Room {
                name: "kitchen-cooker".into(),
                group_name: "hue-lz-kitchen-cooker".into(),
                id: 1,
                members: vec!["hue-l-cooker/11".into()],
                parent: Some("kitchen-all".into()),
                motion_sensors: vec![],
                scenes: day_scenes(vec![1, 2, 3]),
                off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
            },
            Room {
                name: "kitchen-dining".into(),
                group_name: "hue-lz-kitchen-dining".into(),
                id: 2,
                members: vec!["hue-l-dining/11".into()],
                parent: Some("kitchen-all".into()),
                motion_sensors: vec![],
                scenes: day_scenes(vec![1, 2, 3]),
                off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
            },
            Room {
                name: "kitchen-all".into(),
                group_name: "hue-lz-kitchen-all".into(),
                id: 3,
                members: vec![
                    "hue-l-cooker/11".into(),
                    "hue-l-dining/11".into(),
                    "hue-l-empty/11".into(),
                ],
                parent: None,
                motion_sensors: vec![],
                scenes: day_scenes(vec![1, 2, 3]),
                off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
            },
        ],
        bindings: vec![
            scene_toggle_cycle_binding("cooker-tap", "hue-ts-foo", "2", "kitchen-cooker"),
            scene_toggle_cycle_binding("dining-tap", "hue-ts-foo", "3", "kitchen-dining"),
            scene_toggle_cycle_binding("all-tap", "hue-ts-foo", "1", "kitchen-all"),
        ],
        defaults: Defaults::default(),
        heating: None,
        location: None,
    }
}

/// Single-room layout with one wall switch — used for switch action
/// dispatch tests.
pub fn study_switch_config() -> Config {
    Config {
        name_by_address: BTreeMap::new(),
        devices: BTreeMap::from([
            ("hue-l-a".into(), light("0xa")),
            ("hue-s-study".into(), switch_dev("0x1", "test-dimmer")),
        ]),
        switch_models: BTreeMap::from([
            ("test-dimmer".into(), dimmer_model()),
        ]),
        rooms: vec![Room {
            name: "study".into(),
            group_name: "hue-lz-study".into(),
            id: 1,
            members: vec!["hue-l-a/11".into()],
            parent: None,
            motion_sensors: vec![],
            scenes: day_scenes(vec![1, 2, 3]),
            off_transition_seconds: 0.8,
            motion_off_cooldown_seconds: 0,
        }],
        bindings: vec![
            scene_cycle_binding("study-on", "hue-s-study", "on", "study"),
            turn_off_room_binding("study-off", "hue-s-study", "off", "study"),
            Binding {
                name: "study-up".into(),
                trigger: Trigger::Button {
                    device: "hue-s-study".into(),
                    button: "up".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::BrightnessStep { room: "study".into(), step: 25, transition: 0.2 },
            },
            Binding {
                name: "study-down".into(),
                trigger: Trigger::Button {
                    device: "hue-s-study".into(),
                    button: "down".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::BrightnessStep { room: "study".into(), step: -25, transition: 0.2 },
            },
            Binding {
                name: "study-up-hold".into(),
                trigger: Trigger::Button {
                    device: "hue-s-study".into(),
                    button: "up".into(),
                    gesture: Gesture::Hold,
                },
                effect: Effect::BrightnessMove { room: "study".into(), rate: 40 },
            },
            Binding {
                name: "study-down-hold".into(),
                trigger: Trigger::Button {
                    device: "hue-s-study".into(),
                    button: "down".into(),
                    gesture: Gesture::Hold,
                },
                effect: Effect::BrightnessMove { room: "study".into(), rate: -40 },
            },
            Binding {
                name: "study-up-release".into(),
                trigger: Trigger::Button {
                    device: "hue-s-study".into(),
                    button: "up".into(),
                    gesture: Gesture::HoldRelease,
                },
                effect: Effect::BrightnessStop { room: "study".into() },
            },
            Binding {
                name: "study-down-release".into(),
                trigger: Trigger::Button {
                    device: "hue-s-study".into(),
                    button: "down".into(),
                    gesture: Gesture::HoldRelease,
                },
                effect: Effect::BrightnessStop { room: "study".into() },
            },
        ],
        defaults: Defaults::default(),
        heating: None,
        location: None,
    }
}
