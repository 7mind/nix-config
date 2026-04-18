//! Tests for `effect_dispatch`. Split out so `effect_dispatch.rs` stays focused on
//! production code. See `effect_dispatch.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

//! Regression tests for the websocket-broadcast pipeline. The
//! daemon's incremental `broadcast_touched` only fires for
//! entities in the touched set; missing entries here would mean
//! a silently stale dashboard after group/plug/TRV echoes or
//! after parent-room state changes that propagate to children.
//!
//! Relevant Codex review finding (2026-04): inbound state events
//! mutate `WorldState` without emitting effects, and
//! `propagate_to_descendants` mutates child rooms that aren't the
//! direct effect target. Both code paths must show up in
//! `TouchedEntities`.
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Instant;

use super::*;
use crate::config::scenes::{Scene, SceneSchedule, Slot};
use crate::config::switch_model::SwitchModel;
use crate::config::{
    Binding, CommonFields, Config, Defaults, DeviceCatalogEntry, Effect as CfgEffect,
    Room, TimeExpr, Trigger as CfgTrigger,
};
use crate::config::heating::{
    DayTimeRange, HeatPumpProtection, HeatingConfig, HeatingZone, OpenWindowProtection,
    TemperatureSchedule, Weekday, ZoneTrv,
};

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
                from: TimeExpr::Fixed { minute_of_day: 0 },
                to: TimeExpr::Fixed { minute_of_day: 1440 },
                scene_ids: vec![1],
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

fn motion_sensor(ieee: &str) -> DeviceCatalogEntry {
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

fn plug(ieee: &str) -> DeviceCatalogEntry {
    use crate::config::catalog::PlugProtocol;
    DeviceCatalogEntry::Plug {
        common: CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::new(),
        },
        variant: "test-plug".into(),
        capabilities: vec!["on-off".into(), "power".into()],
        protocol: PlugProtocol::Zigbee,
        node_id: None,
    }
}

fn trv(ieee: &str) -> DeviceCatalogEntry {
    DeviceCatalogEntry::Trv(CommonFields {
        ieee_address: ieee.into(),
        description: None,
        options: BTreeMap::from([(
            "operating_mode".into(),
            serde_json::json!("manual"),
        )]),
    })
}

fn wt(ieee: &str) -> DeviceCatalogEntry {
    DeviceCatalogEntry::WallThermostat(CommonFields {
        ieee_address: ieee.into(),
        description: None,
        options: BTreeMap::from([
            ("operating_mode".into(), serde_json::json!("manual")),
            ("heater_type".into(), serde_json::json!("manual_control")),
        ]),
    })
}

fn always_on_schedule() -> TemperatureSchedule {
    let day = vec![DayTimeRange {
        start_hour: 0,
        start_minute: 0,
        end_hour: 24,
        end_minute: 0,
        temperature: 21.0,
    }];
    TemperatureSchedule {
        days: Weekday::ALL.iter().map(|&d| (d, day.clone())).collect(),
    }
}

/// Fixture used by every test in this module. Two rooms
/// (parent + child), one plug, one motion sensor, one heating zone
/// with a TRV and wall thermostat.
fn make_topology_simple() -> Arc<Topology> {
    let cfg = Config {
        name_by_address: BTreeMap::new(),
        devices: BTreeMap::from([
            ("hue-l-parent".into(), light("0xa")),
            ("hue-l-child".into(), light("0xb")),
            ("hue-ms-parent".into(), motion_sensor("0xc")),
            ("z2m-p-test".into(), plug("0xd")),
            ("trv-bath".into(), trv("0xe")),
            ("wt-bath".into(), wt("0xf")),
            ("hue-s-test".into(), DeviceCatalogEntry::Switch {
                common: CommonFields {
                    ieee_address: "0x10".into(),
                    description: None,
                    options: BTreeMap::new(),
                },
                model: "test-1btn".into(),
            }),
        ]),
        switch_models: BTreeMap::from([(
            "test-1btn".into(),
            SwitchModel {
                buttons: vec!["on".into()],
                z2m_action_map: BTreeMap::from([(
                    "on_press".into(),
                    crate::config::switch_model::ActionMapping {
                        button: "on".into(),
                        gesture: crate::config::switch_model::Gesture::Press,
                    },
                )]),
            },
        )]),
        rooms: vec![
            Room {
                name: "parent".into(),
                group_name: "hue-lz-parent".into(),
                id: 1,
                members: vec!["hue-l-parent/11".into(), "hue-l-child/11".into()],
                parent: None,
                motion_sensors: vec!["hue-ms-parent".into()],
                scenes: day_scenes(),
                off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
            },
            Room {
                name: "child".into(),
                group_name: "hue-lz-child".into(),
                id: 2,
                members: vec!["hue-l-child/11".into()],
                parent: Some("parent".into()),
                motion_sensors: vec![],
                scenes: day_scenes(),
                off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
            },
        ],
        bindings: vec![
            // Bind a switch press to the child room so `child` qualifies
            // as a rule-bearing descendant of `parent`.
            Binding {
                name: "child-cycle".into(),
                trigger: CfgTrigger::Button {
                    device: "hue-s-test".into(),
                    button: "on".into(),
                    gesture: crate::config::switch_model::Gesture::Press,
                },
                effect: CfgEffect::SceneCycle { room: "child".into() },
            },
        ],
        defaults: Defaults::default(),
        heating: Some(HeatingConfig {
            zones: vec![HeatingZone {
                name: "bath".into(),
                relay: "wt-bath".into(),
                trvs: vec![ZoneTrv {
                    device: "trv-bath".into(),
                    schedule: "always-on".into(),
                }],
            }],
            schedules: BTreeMap::from([(
                "always-on".into(),
                always_on_schedule(),
            )]),
            pressure_groups: vec![],
            heat_pump: HeatPumpProtection {
                min_cycle_seconds: 60,
                min_pause_seconds: 60,
                min_demand_percent: 5,
                min_demand_percent_fallback: 80,
            },
            open_window: OpenWindowProtection {
                detection_minutes: 20,
                inhibit_minutes: 80,
            },
        }),
        location: None,
    };
    Arc::new(Topology::build(&cfg).expect("build topology"))
}

fn now() -> Instant {
    Instant::now()
}

#[test]
fn touched_from_group_state_includes_room_and_descendants() {
    // Codex regression: a `GroupState` echo for the parent room
    // also propagates to rule-bearing descendants in
    // `handle_group_state`. The dashboard must see updates for
    // both, not just the parent.
    let topo = make_topology_simple();
    let event = Event::GroupState {
        group: "hue-lz-parent".into(),
        on: true,
        ts: now(),
    };
    let touched = touched_from_event(&event, &topo);

    let parent = topo.room_idx("parent").unwrap();
    let child = topo.room_idx("child").unwrap();
    assert!(touched.rooms.contains(&parent), "parent missing from touched set");
    assert!(touched.rooms.contains(&child), "child descendant missing from touched set");
}

#[test]
fn touched_from_plug_state_includes_plug() {
    let topo = make_topology_simple();
    let event = Event::PlugState {
        device: "z2m-p-test".into(),
        on: true,
        power: Some(42.0),
        ts: now(),
    };
    let touched = touched_from_event(&event, &topo);

    let plug = topo.plug_idx_by_name("z2m-p-test").unwrap();
    assert!(touched.plugs.contains(&plug), "plug missing from touched set");
}

#[test]
fn touched_from_plug_power_update_includes_plug() {
    let topo = make_topology_simple();
    let event = Event::PlugPowerUpdate {
        device: "z2m-p-test".into(),
        watts: 1.2,
        ts: now(),
    };
    let touched = touched_from_event(&event, &topo);
    let plug = topo.plug_idx_by_name("z2m-p-test").unwrap();
    assert!(touched.plugs.contains(&plug), "plug missing from touched set");
}

#[test]
fn touched_from_trv_state_includes_zone() {
    let topo = make_topology_simple();
    let event = Event::TrvState {
        device: "trv-bath".into(),
        local_temperature: Some(20.0),
        pi_heating_demand: Some(10),
        running_state: Some("heat".into()),
        occupied_heating_setpoint: Some(21.0),
        operating_mode: Some("manual".into()),
        battery: Some(80),
        ts: now(),
    };
    let touched = touched_from_event(&event, &topo);
    let zone = ZoneIdx::new(0);
    assert!(
        touched.heating_zones.contains(&zone),
        "heating zone missing from touched set after TRV telemetry"
    );
}

#[test]
fn touched_from_wall_thermostat_state_includes_zone() {
    let topo = make_topology_simple();
    let event = Event::WallThermostatState {
        device: "wt-bath".into(),
        relay_on: Some(true),
        local_temperature: Some(20.0),
        operating_mode: Some("manual".into()),
        ts: now(),
    };
    let touched = touched_from_event(&event, &topo);
    let zone = ZoneIdx::new(0);
    assert!(
        touched.heating_zones.contains(&zone),
        "heating zone missing from touched set after WT telemetry"
    );
}

#[test]
fn touched_from_occupancy_includes_motion_room() {
    let topo = make_topology_simple();
    let event = Event::Occupancy {
        sensor: "hue-ms-parent".into(),
        occupied: true,
        illuminance: Some(50),
        ts: now(),
    };
    let touched = touched_from_event(&event, &topo);
    let parent = topo.room_idx("parent").unwrap();
    assert!(touched.rooms.contains(&parent), "motion-driven room missing from touched set");
}

#[test]
fn touched_from_button_press_is_empty() {
    // Effects emitted by `handle_event` will populate the touched
    // set; the event itself contributes nothing structural.
    let topo = make_topology_simple();
    let event = Event::ButtonPress {
        device: "hue-s-test".into(),
        button: "on".into(),
        gesture: crate::config::switch_model::Gesture::Press,
        ts: now(),
    };
    let touched = touched_from_event(&event, &topo);
    assert!(touched.rooms.is_empty());
    assert!(touched.plugs.is_empty());
    assert!(touched.heating_zones.is_empty());
}
