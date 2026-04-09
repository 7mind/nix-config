//! Hand-rolled JSON fixture used by the end-to-end tests. Mirrors the
//! production kitchen layout (parent + 3 sub-zones, each on a separate
//! tap button) so the kitchen-all bug regression has somewhere to live.

use std::collections::BTreeMap;

use hue_controller::config::scenes::{Scene, SceneSchedule, Slot};
use hue_controller::config::{
    CommonFields, Config, DeviceBinding, DeviceCatalogEntry, Defaults, Room,
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
                start_hour: 0,
                end_hour_exclusive: 24,
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

fn tap(ieee: &str) -> DeviceCatalogEntry {
    DeviceCatalogEntry::Tap(CommonFields {
        ieee_address: ieee.into(),
        description: None,
        options: BTreeMap::new(),
    })
}

fn switch(ieee: &str) -> DeviceCatalogEntry {
    DeviceCatalogEntry::Switch(CommonFields {
        ieee_address: ieee.into(),
        description: None,
        options: BTreeMap::new(),
    })
}

fn binding(device: &str, button: Option<u8>) -> DeviceBinding {
    DeviceBinding {
        device: device.into(),
        button,
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
            ("hue-ts-foo".into(), tap("0x1")),
        ]),
        rooms: vec![
            Room {
                name: "kitchen-cooker".into(),
                group_name: "hue-lz-kitchen-cooker".into(),
                id: 1,
                members: vec!["hue-l-cooker/11".into()],
                parent: Some("kitchen-all".into()),
                devices: vec![binding("hue-ts-foo", Some(2))],
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
                devices: vec![binding("hue-ts-foo", Some(3))],
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
                devices: vec![binding("hue-ts-foo", Some(1))],
                scenes: day_scenes(vec![1, 2, 3]),
                off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
            },
        ],
        actions: vec![],
        defaults: Defaults::default(),
    }
}

/// Single-room layout with one wall switch — used for switch action
/// dispatch tests.
pub fn study_switch_config() -> Config {
    Config {
        name_by_address: BTreeMap::new(),
        devices: BTreeMap::from([
            ("hue-l-a".into(), light("0xa")),
            ("hue-s-study".into(), switch("0x1")),
        ]),
        rooms: vec![Room {
            name: "study".into(),
            group_name: "hue-lz-study".into(),
            id: 1,
            members: vec!["hue-l-a/11".into()],
            parent: None,
            devices: vec![binding("hue-s-study", None)],
            scenes: day_scenes(vec![1, 2, 3]),
            off_transition_seconds: 0.8,
            motion_off_cooldown_seconds: 0,
        }],
        actions: vec![],
        defaults: Defaults::default(),
    }
}
