use super::*;
use crate::config::{Binding, CommonFields, Config, Defaults, DeviceCatalogEntry, Effect, Room, Trigger};
use crate::config::scenes::{Scene, SceneSchedule, Slot};
use crate::config::switch_model::{ActionMapping, Gesture, SwitchModel};
use std::collections::BTreeMap;

fn light(ieee: &str) -> DeviceCatalogEntry {
    DeviceCatalogEntry::Light(CommonFields {
        ieee_address: ieee.into(),
        description: None,
        options: BTreeMap::new(),
    })
}

fn switch_dev(ieee: &str) -> DeviceCatalogEntry {
    DeviceCatalogEntry::Switch {
        common: CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::new(),
        },
        model: "test-dimmer".into(),
    }
}

fn switch_dev_model(ieee: &str, model: &str) -> DeviceCatalogEntry {
    DeviceCatalogEntry::Switch {
        common: CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::new(),
        },
        model: model.into(),
    }
}

fn motion(ieee: &str) -> DeviceCatalogEntry {
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

/// Trivial day-only scene schedule for tests that don't care about slots.
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

fn room(
    name: &str,
    id: u8,
    members: Vec<&str>,
    motion_sensors: Vec<&str>,
    parent: Option<&str>,
) -> Room {
    Room {
        name: name.into(),
        group_name: format!("hue-lz-{name}"),
        id,
        members: members.into_iter().map(String::from).collect(),
        parent: parent.map(String::from),
        motion_sensors: motion_sensors.into_iter().map(String::from).collect(),
        scenes: day_scenes(),
        off_transition_seconds: 0.8,
        motion_off_cooldown_seconds: 0,
    }
}

fn room_with_group_name(
    name: &str,
    id: u8,
    group_name: &str,
    members: Vec<&str>,
    parent: Option<&str>,
) -> Room {
    Room {
        name: name.into(),
        group_name: group_name.into(),
        id,
        members: members.into_iter().map(String::from).collect(),
        parent: parent.map(String::from),
        motion_sensors: vec![],
        scenes: day_scenes(),
        off_transition_seconds: 0.8,
        motion_off_cooldown_seconds: 0,
    }
}

fn plug_dev(ieee: &str, variant: &str, caps: &[&str]) -> DeviceCatalogEntry {
    DeviceCatalogEntry::Plug {
        common: CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::new(),
        },
        variant: variant.into(),
        capabilities: caps.iter().map(|s| s.to_string()).collect(),
        protocol: PlugProtocol::default(),
        node_id: None,
    }
}

fn zwave_plug_dev(node_id: u16, variant: &str, caps: &[&str]) -> DeviceCatalogEntry {
    DeviceCatalogEntry::Plug {
        common: CommonFields {
            ieee_address: format!("zwave:{node_id}"),
            description: None,
            options: BTreeMap::new(),
        },
        variant: variant.into(),
        capabilities: caps.iter().map(|s| s.to_string()).collect(),
        protocol: PlugProtocol::Zwave,
        node_id: Some(node_id),
    }
}

/// Minimal switch model with on/off/up/down buttons, press-only gestures.
fn test_dimmer_model() -> SwitchModel {
    SwitchModel {
        buttons: vec!["on".into(), "off".into(), "up".into(), "down".into()],
        z2m_action_map: BTreeMap::from([
            ("on_press_release".into(), ActionMapping { button: "on".into(), gesture: Gesture::Press }),
            ("off_press_release".into(), ActionMapping { button: "off".into(), gesture: Gesture::Press }),
            ("up_press_release".into(), ActionMapping { button: "up".into(), gesture: Gesture::Press }),
            ("down_press_release".into(), ActionMapping { button: "down".into(), gesture: Gesture::Press }),
        ]),
    }
}

/// Model with hardware double-tap (Sonoff-style).
fn test_hw_double_tap_model() -> SwitchModel {
    SwitchModel {
        buttons: vec!["1".into(), "2".into()],
        z2m_action_map: BTreeMap::from([
            ("single_button_1".into(), ActionMapping { button: "1".into(), gesture: Gesture::Press }),
            ("single_button_2".into(), ActionMapping { button: "2".into(), gesture: Gesture::Press }),
            ("double_button_1".into(), ActionMapping { button: "1".into(), gesture: Gesture::DoubleTap }),
            ("double_button_2".into(), ActionMapping { button: "2".into(), gesture: Gesture::DoubleTap }),
        ]),
    }
}

/// Minimal tap model with numbered buttons.
fn test_tap_model() -> SwitchModel {
    SwitchModel {
        buttons: vec!["1".into(), "2".into(), "3".into(), "4".into()],
        z2m_action_map: BTreeMap::from([
            ("1_single".into(), ActionMapping { button: "1".into(), gesture: Gesture::Press }),
            ("2_single".into(), ActionMapping { button: "2".into(), gesture: Gesture::Press }),
            ("3_single".into(), ActionMapping { button: "3".into(), gesture: Gesture::Press }),
            ("4_single".into(), ActionMapping { button: "4".into(), gesture: Gesture::Press }),
        ]),
    }
}

fn default_switch_models() -> BTreeMap<String, SwitchModel> {
    BTreeMap::from([
        ("test-dimmer".into(), test_dimmer_model()),
        ("test-tap".into(), test_tap_model()),
        ("test-hw-dbl".into(), test_hw_double_tap_model()),
    ])
}

fn config(devices: Vec<(&str, DeviceCatalogEntry)>, rooms: Vec<Room>) -> Config {
    config_with_bindings(devices, rooms, vec![])
}

fn config_with_bindings(
    devices: Vec<(&str, DeviceCatalogEntry)>,
    rooms: Vec<Room>,
    bindings: Vec<Binding>,
) -> Config {
    let devices = devices
        .into_iter()
        .map(|(n, e)| (n.to_string(), e))
        .collect();
    Config {
        name_by_address: BTreeMap::new(),
        devices,
        switch_models: default_switch_models(),
        rooms,
        bindings,
        defaults: Default::default(),
        heating: None,
        location: None,
    }
}

/// Test helper: look up a binding's index by name (callers want
/// stable indexes for assertions).
fn binding_idx_by_name(topo: &Topology, name: &str) -> BindingIdx {
    topo.bindings()
        .iter()
        .enumerate()
        .find(|(_, b)| b.name == name)
        .map(|(i, _)| BindingIdx::new(i as u32))
        .unwrap_or_else(|| panic!("binding {name:?} not found"))
}

#[test]
fn empty_config_builds() {
    let cfg = config(vec![], vec![]);
    let topo = Topology::build(&cfg).unwrap();
    assert!(topo.rooms().next().is_none());
}

#[test]
fn room_with_switch_binding_builds_and_indexes() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-s-a", switch_dev("0x1")),
        ],
        vec![room("study", 1, vec!["hue-l-a/11"], vec![], None)],
        vec![Binding {
            name: "study-on".into(),
            trigger: Trigger::Button {
                device: "hue-s-a".into(),
                button: "on".into(),
                gesture: Gesture::Press,
            },
            effect: Effect::SceneCycle { room: "study".into() },
        }],
    );
    let topo = Topology::build(&cfg).unwrap();
    let study_idx = topo.room_idx("study").unwrap();
    let r = topo.room_by_name("study").unwrap();
    assert!(r.bound_motion.is_empty());
    assert!(topo.room_has_rules(study_idx));

    let switch_idx = topo.device_idx("hue-s-a").unwrap();
    assert_eq!(
        topo.bindings_for_button(switch_idx, "on", Gesture::Press),
        &[BindingIdx::new(0)]
    );
    assert_eq!(topo.room_by_group_name("hue-lz-study").unwrap().name, "study");
}

#[test]
fn motion_sensor_binding_routes_to_room() {
    let cfg = config(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-ms-a", motion("0x3")),
        ],
        vec![room("study", 1, vec!["hue-l-a/11"], vec!["hue-ms-a"], None)],
    );
    let topo = Topology::build(&cfg).unwrap();
    let r = topo.room_by_name("study").unwrap();
    assert!(r.has_motion_sensor());
    assert_eq!(r.bound_motion.len(), 1);
    assert_eq!(r.bound_motion[0].sensor, "hue-ms-a");
    let study_idx = topo.room_idx("study").unwrap();
    assert_eq!(topo.rooms_for_motion("hue-ms-a"), &[study_idx]);
}

#[test]
fn motion_sensor_not_in_catalog_rejected() {
    let cfg = config(
        vec![("hue-l-a", light("0xa"))],
        vec![room("study", 1, vec!["hue-l-a/11"], vec!["hue-ms-ghost"], None)],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::MotionSensorNotInCatalog { .. }));
}

#[test]
fn motion_sensor_wrong_kind_rejected() {
    let cfg = config(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-s-a", switch_dev("0x1")),
        ],
        vec![room("study", 1, vec!["hue-l-a/11"], vec!["hue-s-a"], None)],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::MotionSensorWrongKind { kind: "switch", .. }));
}

#[test]
fn button_binding_routes_to_correct_index() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-l-b", light("0xb")),
            ("hue-ts-foo", switch_dev_model("0x1", "test-tap")),
        ],
        vec![
            room(
                "kitchen-cooker", 1, vec!["hue-l-a/11"], vec![],
                Some("kitchen-all"),
            ),
            room(
                "kitchen-all", 2, vec!["hue-l-a/11", "hue-l-b/11"], vec![],
                None,
            ),
        ],
        vec![
            Binding {
                name: "cooker-tap".into(),
                trigger: Trigger::Button {
                    device: "hue-ts-foo".into(),
                    button: "2".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::SceneToggleCycle { room: "kitchen-cooker".into() },
            },
            Binding {
                name: "all-tap".into(),
                trigger: Trigger::Button {
                    device: "hue-ts-foo".into(),
                    button: "1".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::SceneToggleCycle { room: "kitchen-all".into() },
            },
        ],
    );
    let topo = Topology::build(&cfg).unwrap();

    let switch_idx = topo.device_idx("hue-ts-foo").unwrap();
    let cooker_idx = binding_idx_by_name(&topo, "cooker-tap");
    let all_idx = binding_idx_by_name(&topo, "all-tap");
    assert_eq!(
        topo.bindings_for_button(switch_idx, "1", Gesture::Press),
        &[all_idx]
    );
    assert_eq!(
        topo.bindings_for_button(switch_idx, "2", Gesture::Press),
        &[cooker_idx]
    );
    assert!(topo.bindings_for_button(switch_idx, "3", Gesture::Press).is_empty());
}

#[test]
fn duplicate_group_id_rejected() {
    let cfg = config(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-l-b", light("0xb")),
        ],
        vec![
            room("a", 1, vec!["hue-l-a/11"], vec![], None),
            room("b", 1, vec!["hue-l-b/11"], vec![], None),
        ],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::DuplicateGroupId { id: 1, .. }));
}

#[test]
fn duplicate_group_friendly_name_rejected() {
    let cfg = config(
        vec![("hue-l-a", light("0xa"))],
        vec![
            Room {
                name: "a".into(),
                group_name: "shared".into(),
                id: 1,
                members: vec!["hue-l-a/11".into()],
                parent: None,
                motion_sensors: vec![],
                scenes: day_scenes(),
                off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
            },
            Room {
                name: "b".into(),
                group_name: "shared".into(),
                id: 2,
                members: vec!["hue-l-a/11".into()],
                parent: None,
                motion_sensors: vec![],
                scenes: day_scenes(),
                off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
            },
        ],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(
        err,
        TopologyError::DuplicateGroupName { name, .. } if name == "shared"
    ));
}

#[test]
fn group_name_device_collision_rejected() {
    // Group name "z2m-p-foo" collides with a plug in the device catalog.
    let cfg = config(
        vec![
            ("hue-l-a", light("0xa")),
            ("z2m-p-foo", plug_dev("0xf", "sonoff-basic", &["on-off"])),
        ],
        vec![room_with_group_name(
            "a", 1, "z2m-p-foo",
            vec!["hue-l-a/11"], None,
        )],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::GroupNameDeviceCollision { .. }));
}

#[test]
fn unknown_parent_rejected() {
    let cfg = config(
        vec![("hue-l-a", light("0xa"))],
        vec![room("child", 1, vec!["hue-l-a/11"], vec![], Some("ghost"))],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::UnknownParent { .. }));
}

#[test]
fn self_parent_rejected() {
    let cfg = config(
        vec![("hue-l-a", light("0xa"))],
        vec![room("loop", 1, vec!["hue-l-a/11"], vec![], Some("loop"))],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::SelfParent(_)));
}

#[test]
fn parent_chain_cycle_rejected() {
    let cfg = config(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-l-b", light("0xb")),
        ],
        vec![
            room("a", 1, vec!["hue-l-a/11"], vec![], Some("b")),
            room("b", 2, vec!["hue-l-b/11"], vec![], Some("a")),
        ],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::ParentChainCycle { .. }));
}

#[test]
fn member_referencing_non_light_rejected() {
    let cfg = config(
        vec![("hue-s-a", switch_dev("0x1"))],
        vec![room("a", 1, vec!["hue-s-a/11"], vec![], None)],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::UnknownMemberLight { .. }));
}

#[test]
fn malformed_member_rejected() {
    let cfg = config(
        vec![("hue-l-a", light("0xa"))],
        vec![room("a", 1, vec!["hue-l-a"], vec![], None)],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::MalformedMember { .. }));
}

#[test]
fn binding_toggle_plug_builds_and_indexes() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-ts-foo", switch_dev_model("0x1", "test-tap")),
            ("z2m-p-printer", plug_dev("0xf", "sonoff-power", &["on-off", "power"])),
        ],
        vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
        vec![Binding {
            name: "printer-toggle".into(),
            trigger: Trigger::Button {
                device: "hue-ts-foo".into(),
                button: "3".into(),
                gesture: Gesture::Press,
            },
            effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-printer".into() },
        }],
    );
    let topo = Topology::build(&cfg).unwrap();
    assert_eq!(topo.bindings().len(), 1);
    let switch_idx = topo.device_idx("hue-ts-foo").unwrap();
    let printer_toggle = binding_idx_by_name(&topo, "printer-toggle");
    assert_eq!(topo.bindings_for_button(switch_idx, "3", Gesture::Press), &[printer_toggle]);
    assert!(topo.bindings_for_button(switch_idx, "1", Gesture::Press).is_empty());
    assert!(topo.is_plug("z2m-p-printer"));
    assert!(!topo.is_plug("hue-l-a"));
}

#[test]
fn binding_switch_on_off_builds_and_indexes() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-s-office", switch_dev("0x1")),
            ("z2m-p-lamp", plug_dev("0xf", "sonoff-basic", &["on-off"])),
        ],
        vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
        vec![
            Binding {
                name: "lamp-on".into(),
                trigger: Trigger::Button {
                    device: "hue-s-office".into(),
                    button: "on".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::TurnOn { target: "z2m-p-lamp".into() },
            },
            Binding {
                name: "lamp-off".into(),
                trigger: Trigger::Button {
                    device: "hue-s-office".into(),
                    button: "off".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::TurnOff { target: "z2m-p-lamp".into() },
            },
        ],
    );
    let topo = Topology::build(&cfg).unwrap();
    assert_eq!(topo.bindings().len(), 2);
    let switch_idx = topo.device_idx("hue-s-office").unwrap();
    let lamp_on = binding_idx_by_name(&topo, "lamp-on");
    let lamp_off = binding_idx_by_name(&topo, "lamp-off");
    assert_eq!(topo.bindings_for_button(switch_idx, "on", Gesture::Press), &[lamp_on]);
    assert_eq!(topo.bindings_for_button(switch_idx, "off", Gesture::Press), &[lamp_off]);
}

#[test]
fn binding_power_below_builds_and_indexes() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("z2m-p-printer", plug_dev("0xf", "sonoff-power", &["on-off", "power"])),
        ],
        vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
        vec![Binding {
            name: "printer-kill".into(),
            trigger: Trigger::PowerBelow {
                device: "z2m-p-printer".into(),
                watts: 5.0,
                for_seconds: 300,
            },
            effect: Effect::TurnOff { target: "z2m-p-printer".into() },
        }],
    );
    let topo = Topology::build(&cfg).unwrap();
    let printer_idx = topo.device_idx("z2m-p-printer").unwrap();
    let kill = binding_idx_by_name(&topo, "printer-kill");
    assert_eq!(topo.bindings_for_power_below(printer_idx), &[kill]);
}

#[test]
fn binding_power_below_without_capability_rejected() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("z2m-p-basic", plug_dev("0xf", "sonoff-basic", &["on-off"])),
        ],
        vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
        vec![Binding {
            name: "kill".into(),
            trigger: Trigger::PowerBelow {
                device: "z2m-p-basic".into(),
                watts: 5.0,
                for_seconds: 300,
            },
            effect: Effect::TurnOff { target: "z2m-p-basic".into() },
        }],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::BindingPowerBelowWithoutCapability { .. }));
}

#[test]
fn binding_trigger_wrong_device_kind_rejected() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("z2m-p-printer", plug_dev("0xf", "sonoff-power", &["on-off", "power"])),
        ],
        vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
        vec![Binding {
            name: "bad".into(),
            trigger: Trigger::Button {
                device: "hue-l-a".into(),
                button: "1".into(),
                gesture: Gesture::Press,
            },
            effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-printer".into() },
        }],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::BindingTriggerWrongDeviceKind { .. }));
}

#[test]
fn binding_button_not_in_model_rejected() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-ts-foo", switch_dev_model("0x1", "test-tap")),
            ("z2m-p-a", plug_dev("0xf", "sonoff-basic", &["on-off"])),
        ],
        vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
        vec![Binding {
            name: "bad".into(),
            trigger: Trigger::Button {
                device: "hue-ts-foo".into(),
                button: "nonexistent".into(),
                gesture: Gesture::Press,
            },
            effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-a".into() },
        }],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::BindingButtonNotInModel { .. }));
}

#[test]
fn binding_effect_not_plug_rejected() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-ts-foo", switch_dev_model("0x1", "test-tap")),
        ],
        vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
        vec![Binding {
            name: "bad".into(),
            trigger: Trigger::Button {
                device: "hue-ts-foo".into(),
                button: "1".into(),
                gesture: Gesture::Press,
            },
            effect: Effect::Toggle { confirm_off_seconds: None, target: "hue-l-a".into() },
        }],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::BindingEffectNotPlug { .. }));
}

#[test]
fn duplicate_binding_name_rejected() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-ts-foo", switch_dev_model("0x1", "test-tap")),
            ("z2m-p-a", plug_dev("0xf", "sonoff-basic", &["on-off"])),
        ],
        vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
        vec![
            Binding {
                name: "dupe".into(),
                trigger: Trigger::Button {
                    device: "hue-ts-foo".into(),
                    button: "1".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-a".into() },
            },
            Binding {
                name: "dupe".into(),
                trigger: Trigger::Button {
                    device: "hue-ts-foo".into(),
                    button: "2".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-a".into() },
            },
        ],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::DuplicateBindingName(_)));
}

#[test]
fn binding_trigger_unknown_device_rejected() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("z2m-p-a", plug_dev("0xf", "sonoff-basic", &["on-off"])),
        ],
        vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
        vec![Binding {
            name: "bad".into(),
            trigger: Trigger::Button {
                device: "ghost".into(),
                button: "1".into(),
                gesture: Gesture::Press,
            },
            effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-a".into() },
        }],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::BindingTriggerUnknownDevice { .. }));
}

#[test]
fn binding_effect_unknown_device_rejected() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-ts-foo", switch_dev_model("0x1", "test-tap")),
        ],
        vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
        vec![Binding {
            name: "bad".into(),
            trigger: Trigger::Button {
                device: "hue-ts-foo".into(),
                button: "1".into(),
                gesture: Gesture::Press,
            },
            effect: Effect::Toggle { confirm_off_seconds: None, target: "ghost".into() },
        }],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::BindingEffectUnknownDevice { .. }));
}

#[test]
fn binding_room_not_found_rejected() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-s-a", switch_dev("0x1")),
        ],
        vec![room("study", 1, vec!["hue-l-a/11"], vec![], None)],
        vec![Binding {
            name: "ghost-room".into(),
            trigger: Trigger::Button {
                device: "hue-s-a".into(),
                button: "on".into(),
                gesture: Gesture::Press,
            },
            effect: Effect::SceneCycle { room: "nonexistent".into() },
        }],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::BindingRoomNotFound { .. }));
}

#[test]
fn descendants_filter_rule_less_rooms() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-l-b", light("0xb")),
            ("hue-l-c", light("0xc")),
            ("hue-s-cooker", switch_dev("0x1")),
            ("hue-s-all", switch_dev("0x2")),
        ],
        vec![
            room(
                "kitchen-cooker", 1, vec!["hue-l-a/11"], vec![],
                Some("kitchen-all"),
            ),
            // Rule-less child: no bindings, no motion sensors.
            room(
                "kitchen-empty", 2, vec!["hue-l-b/11"], vec![],
                Some("kitchen-all"),
            ),
            room(
                "kitchen-all", 3,
                vec!["hue-l-a/11", "hue-l-b/11", "hue-l-c/11"],
                vec![], None,
            ),
        ],
        vec![
            Binding {
                name: "cooker-on".into(),
                trigger: Trigger::Button {
                    device: "hue-s-cooker".into(),
                    button: "on".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::SceneCycle { room: "kitchen-cooker".into() },
            },
            Binding {
                name: "all-on".into(),
                trigger: Trigger::Button {
                    device: "hue-s-all".into(),
                    button: "on".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::SceneCycle { room: "kitchen-all".into() },
            },
        ],
    );
    let topo = Topology::build(&cfg).unwrap();
    // Only kitchen-cooker has rules; kitchen-empty is filtered out.
    let all_idx = topo.room_idx("kitchen-all").unwrap();
    let cooker_idx = topo.room_idx("kitchen-cooker").unwrap();
    assert_eq!(topo.descendants_of(all_idx), &[cooker_idx]);
}

#[test]
fn power_below_cross_target_rejected() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("z2m-p-monitor", plug_dev("0xf1", "sonoff-power", &["on-off", "power"])),
            ("z2m-p-target", plug_dev("0xf2", "sonoff-power", &["on-off", "power"])),
        ],
        vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
        vec![Binding {
            name: "cross-kill".into(),
            trigger: Trigger::PowerBelow {
                device: "z2m-p-monitor".into(),
                watts: 5.0,
                for_seconds: 300,
            },
            effect: Effect::TurnOff { target: "z2m-p-target".into() },
        }],
    );
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::PowerBelowCrossTarget { .. }));
}

#[test]
fn transitive_descendants_through_rule_less_intermediate() {
    // grandparent → parent (rule-less) → child (with rules)
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-l-b", light("0xb")),
            ("hue-l-c", light("0xc")),
            ("hue-s-child", switch_dev("0x1")),
            ("hue-s-grand", switch_dev("0x2")),
        ],
        vec![
            room("child", 1, vec!["hue-l-a/11"], vec![], Some("parent")),
            room("parent", 2, vec!["hue-l-b/11"], vec![], Some("grand")),
            room("grand", 3, vec!["hue-l-c/11"], vec![], None),
        ],
        vec![
            Binding {
                name: "child-on".into(),
                trigger: Trigger::Button {
                    device: "hue-s-child".into(),
                    button: "on".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::SceneCycle { room: "child".into() },
            },
            Binding {
                name: "grand-on".into(),
                trigger: Trigger::Button {
                    device: "hue-s-grand".into(),
                    button: "on".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::SceneCycle { room: "grand".into() },
            },
        ],
    );
    let topo = Topology::build(&cfg).unwrap();
    let grand_idx = topo.room_idx("grand").unwrap();
    let parent_idx = topo.room_idx("parent").unwrap();
    let child_idx = topo.room_idx("child").unwrap();
    // grand's descendants: child (parent is rule-less, filtered out)
    assert_eq!(topo.descendants_of(grand_idx), &[child_idx]);
    // parent's descendants: child
    assert_eq!(topo.descendants_of(parent_idx), &[child_idx]);
}

#[test]
fn negative_double_tap_suppression_rejected() {
    let cfg = Config {
        name_by_address: BTreeMap::new(),
        devices: BTreeMap::from([
            ("hue-l-a".into(), light("0xa")),
        ]),
        switch_models: default_switch_models(),
        rooms: vec![room("r", 1, vec!["hue-l-a/11"], vec![], None)],
        bindings: vec![],
        defaults: Defaults {
            double_tap_suppression_seconds: -1.0,
            ..Defaults::default()
        },
        heating: None,
        location: None,
    };
    assert_eq!(
        Topology::build(&cfg).unwrap_err(),
        TopologyError::NegativeDoubleTapSuppression(-1.0),
    );
}

#[test]
fn soft_double_tap_buttons_tracked() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-s-a", switch_dev("0x1")),
        ],
        vec![room("study", 1, vec!["hue-l-a/11"], vec![], None)],
        vec![
            Binding {
                name: "study-on".into(),
                trigger: Trigger::Button {
                    device: "hue-s-a".into(),
                    button: "on".into(),
                    gesture: Gesture::Press,
                },
                effect: Effect::SceneCycle { room: "study".into() },
            },
            Binding {
                name: "all-off-dbl".into(),
                trigger: Trigger::Button {
                    device: "hue-s-a".into(),
                    button: "on".into(),
                    gesture: Gesture::SoftDoubleTap,
                },
                effect: Effect::TurnOffAllZones,
            },
        ],
    );
    let topo = Topology::build(&cfg).unwrap();
    let switch_idx = topo.device_idx("hue-s-a").unwrap();
    assert!(topo.is_soft_double_tap_button(switch_idx, "on"));
    assert!(!topo.is_soft_double_tap_button(switch_idx, "off"));
}

#[test]
fn hw_double_tap_buttons_tracked() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("sonoff-orb", switch_dev_model("0x1", "test-hw-dbl")),
        ],
        vec![room("study", 1, vec!["hue-l-a/11"], vec![], None)],
        vec![Binding {
            name: "orb-1".into(),
            trigger: Trigger::Button {
                device: "sonoff-orb".into(),
                button: "1".into(),
                gesture: Gesture::Press,
            },
            effect: Effect::SceneCycle { room: "study".into() },
        }],
    );
    let topo = Topology::build(&cfg).unwrap();
    let switch_idx = topo.device_idx("sonoff-orb").unwrap();
    assert!(topo.is_hw_double_tap_button(switch_idx, "1"));
    assert!(topo.is_hw_double_tap_button(switch_idx, "2"));
}

#[test]
fn hw_double_tap_is_per_button() {
    // Model where only button "1" has both press+double_tap,
    // button "2" only has press.
    let partial_model = SwitchModel {
        buttons: vec!["1".into(), "2".into()],
        z2m_action_map: BTreeMap::from([
            ("single_button_1".into(), ActionMapping { button: "1".into(), gesture: Gesture::Press }),
            ("single_button_2".into(), ActionMapping { button: "2".into(), gesture: Gesture::Press }),
            ("double_button_1".into(), ActionMapping { button: "1".into(), gesture: Gesture::DoubleTap }),
            // no double_button_2 — button "2" lacks HW double-tap
        ]),
    };
    let mut models = default_switch_models();
    models.insert("partial-dbl".into(), partial_model);
    let cfg = Config {
        name_by_address: BTreeMap::new(),
        switch_models: models,
        devices: BTreeMap::from([
            ("hue-l-a".into(), light("0xa")),
            ("sw-partial".into(), switch_dev_model("0x1", "partial-dbl")),
        ]),
        rooms: vec![room("study", 1, vec!["hue-l-a/11"], vec![], None)],
        bindings: vec![Binding {
            name: "partial-1".into(),
            trigger: Trigger::Button {
                device: "sw-partial".into(),
                button: "1".into(),
                gesture: Gesture::Press,
            },
            effect: Effect::SceneCycle { room: "study".into() },
        }],
        defaults: Defaults::default(),
        heating: None,
        location: None,
    };
    let topo = Topology::build(&cfg).unwrap();
    let switch_idx = topo.device_idx("sw-partial").unwrap();
    assert!(topo.is_hw_double_tap_button(switch_idx, "1"));
    assert!(!topo.is_hw_double_tap_button(switch_idx, "2"));
}

#[test]
fn switch_model_lookup() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-s-a", switch_dev("0x1")),
        ],
        vec![room("study", 1, vec!["hue-l-a/11"], vec![], None)],
        vec![],
    );
    let topo = Topology::build(&cfg).unwrap();
    let switch_idx = topo.device_idx("hue-s-a").unwrap();
    let light_idx = topo.device_idx("hue-l-a").unwrap();
    assert_eq!(topo.switch_model_for(switch_idx), Some("test-dimmer"));
    assert_eq!(topo.switch_model_for(light_idx), None);
}

#[test]
fn unknown_switch_model_rejected() {
    let devices: BTreeMap<String, DeviceCatalogEntry> = BTreeMap::from([
        ("hue-l-a".into(), light("0xa")),
        ("hue-s-a".into(), DeviceCatalogEntry::Switch {
            common: CommonFields {
                ieee_address: "0x1".into(),
                description: None,
                options: BTreeMap::new(),
            },
            model: "nonexistent-model".into(),
        }),
    ]);
    let cfg = Config {
        name_by_address: BTreeMap::new(),
        devices,
        switch_models: default_switch_models(),
        rooms: vec![room("study", 1, vec!["hue-l-a/11"], vec![], None)],
        bindings: vec![],
        defaults: Default::default(),
        heating: None,
        location: None,
    };
    let err = Topology::build(&cfg).unwrap_err();
    assert!(matches!(err, TopologyError::UnknownSwitchModel { .. }));
}

#[test]
fn all_switch_device_names_populated() {
    let cfg = config_with_bindings(
        vec![
            ("hue-l-a", light("0xa")),
            ("hue-s-a", switch_dev("0x1")),
            ("hue-s-b", switch_dev("0x2")),
        ],
        vec![room("study", 1, vec!["hue-l-a/11"], vec![], None)],
        vec![],
    );
    let topo = Topology::build(&cfg).unwrap();
    let names = topo.all_switch_device_names();
    assert!(names.contains(&"hue-s-a"));
    assert!(names.contains(&"hue-s-b"));
    assert!(!names.contains(&"hue-l-a"));
}

#[test]
fn zwave_plug_indexed_by_node_id() {
    let cfg = config(
        vec![
            ("hue-l-a", light("0xa")),
            ("z2m-p-zw", zwave_plug_dev(7, "neo-nas-wr01ze", &["on-off", "power"])),
        ],
        vec![room("a", 1, vec!["hue-l-a/11"], vec![], None)],
    );
    let topo = Topology::build(&cfg).unwrap();
    let map = topo.zwave_node_id_to_name();
    assert_eq!(map.get(&7), Some(&"z2m-p-zw"));
}
