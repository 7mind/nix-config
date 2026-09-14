//! Behavioral blackbox tests for independently scheduled motion rules.
use std::sync::Arc;
use std::time::Duration;

use mqtt_controller::config::Config;
use mqtt_controller::domain::event::Event;
use mqtt_controller::logic::EventProcessor;
use mqtt_controller::time::{Clock, FakeClock};
use mqtt_controller::topology::Topology;
use serde_json::json;

fn config() -> Config {
    let scenes = json!({
        "scenes": [{"id": 1, "name": "warm", "state": "ON", "brightness": 160,
                    "color_temp": 454, "transition": 0.5}],
        "slots": {
            "morning": {"from": "05:00", "to": "06:00", "scene_ids": [1]},
            "day": {"from": "06:00", "to": "18:00", "scene_ids": [1]},
            "evening": {"from": "18:00", "to": "22:00", "scene_ids": [1]},
            "night": {"from": "22:00", "to": "05:00", "scene_ids": [1]}
        }
    });
    serde_json::from_value(json!({
        "devices": {
            "wall": {"kind": "light", "ieee_address": "0xa"},
            "ceiling": {"kind": "light", "ieee_address": "0xb"},
            "sensor": {"kind": "motion-sensor", "ieee_address": "0xc",
                       "occupancy_timeout_seconds": 180}
        },
        "rooms": [{
            "name": "bathroom", "group_name": "bathroom-all", "id": 1,
            "members": ["wall/11", "ceiling/11"], "scenes": scenes,
            "off_transition_seconds": 0.8
        }],
        "motion_rules": [{
            "name": "bathroom-motion", "sensors": ["sensor"], "mode": "on-off",
            "scenes": scenes, "off_transition_seconds": 0.8, "off_cooldown_seconds": 0,
            "targets_by_slot": {
                "day": {"group": "bathroom"},
                "evening": {"lights": ["wall/11"]},
                "night": {"lights": ["wall/11"]},
                "morning": {"lights": ["wall/11"]}
            }
        }]
    }))
    .expect("standalone motion rules must deserialize")
}

#[test]
fn wall_only_motion_keeps_its_target_across_a_schedule_boundary() {
    let cfg = config();
    let topology = Arc::new(Topology::build(&cfg).unwrap());
    let clock = Arc::new(FakeClock::new(23));
    let mut processor = EventProcessor::new(topology.clone(), clock.clone(), cfg.defaults, None);
    let on = processor.handle_event(Event::Occupancy {
        sensor: "sensor".into(),
        occupied: true,
        illuminance: Some(0),
        ts: clock.now(),
    });
    assert_eq!(on.len(), 1);
    assert_eq!(on[0].topic(&topology), "zigbee2mqtt/wall/11/set");
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&on[0].payload_string()).unwrap(),
        json!({"state": "ON", "brightness": 160, "color_temp": 454, "transition": 0.5})
    );
    clock.set_hour(7);
    clock.advance(Duration::from_secs(180));
    let off = processor.handle_event(Event::Occupancy {
        sensor: "sensor".into(),
        occupied: false,
        illuminance: Some(0),
        ts: clock.now(),
    });
    assert_eq!(off.len(), 1);
    assert_eq!(off[0].topic(&topology), "zigbee2mqtt/wall/11/set");
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&off[0].payload_string()).unwrap(),
        json!({"state": "OFF", "transition": 0.8})
    );
}

fn processor(cfg: Config, hour: u8) -> (EventProcessor, Arc<Topology>, Arc<FakeClock>) {
    let topology = Arc::new(Topology::build(&cfg).unwrap());
    let clock = Arc::new(FakeClock::new(hour));
    (
        EventProcessor::new(topology.clone(), clock.clone(), cfg.defaults, None),
        topology,
        clock,
    )
}

fn occupancy(clock: &FakeClock, occupied: bool) -> Event {
    Event::Occupancy {
        sensor: "sensor".into(),
        occupied,
        illuminance: Some(0),
        ts: clock.now(),
    }
}

#[test]
fn slot_selects_wall_or_existing_group() {
    for (hour, topic) in [
        (5, "wall/11"),
        (12, "bathroom-all"),
        (19, "wall/11"),
        (23, "wall/11"),
    ] {
        let (mut p, topology, clock) = processor(config(), hour);
        let effects = p.handle_event(occupancy(&clock, true));
        assert_eq!(effects.len(), 1);
        assert_eq!(
            effects[0].topic(&topology),
            format!("zigbee2mqtt/{topic}/set")
        );
    }
}

#[test]
fn daytime_session_still_turns_off_whole_group_after_dark() {
    let (mut p, topology, clock) = processor(config(), 12);
    p.handle_event(occupancy(&clock, true));
    clock.set_hour(23);
    let effects = p.handle_event(occupancy(&clock, false));
    assert_eq!(effects.len(), 1);
    assert_eq!(effects[0].topic(&topology), "zigbee2mqtt/bathroom-all/set");
}

#[test]
fn manual_scene_takes_over_wall_motion() {
    let (mut p, _, clock) = processor(config(), 23);
    p.handle_event(occupancy(&clock, true));
    assert_eq!(p.web_recall_scene("bathroom", 1, clock.now()).len(), 1);
    assert!(p.handle_event(occupancy(&clock, false)).is_empty());
}

#[test]
fn off_only_keeps_only_selected_light_after_manual_group_scene() {
    let mut cfg = config();
    cfg.motion_rules[0].mode = mqtt_controller::config::MotionMode::OffOnly;
    let (mut p, topology, clock) = processor(cfg, 23);
    assert!(p.handle_event(occupancy(&clock, true)).is_empty());
    p.web_recall_scene("bathroom", 1, clock.now());
    let effects = p.handle_event(occupancy(&clock, false));
    assert_eq!(effects.len(), 1);
    assert_eq!(effects[0].topic(&topology), "zigbee2mqtt/wall/11/set");
}

#[test]
fn on_only_does_not_turn_off_on_vacancy() {
    let mut cfg = config();
    cfg.motion_rules[0].mode = mqtt_controller::config::MotionMode::OnOnly;
    let (mut p, _, clock) = processor(cfg, 23);
    assert_eq!(p.handle_event(occupancy(&clock, true)).len(), 1);
    assert!(p.handle_event(occupancy(&clock, false)).is_empty());
}

#[test]
fn stale_sensor_cleanup_uses_pinned_subset() {
    let (mut p, topology, clock) = processor(config(), 23);
    p.handle_event(occupancy(&clock, true));
    clock.advance(Duration::from_secs(3600));
    clock.set_hour(12);
    let effects = p.handle_event(Event::Tick { ts: clock.now() });
    assert_eq!(effects.len(), 1);
    assert_eq!(effects[0].topic(&topology), "zigbee2mqtt/wall/11/set");
}

#[test]
fn invalid_rule_targets_are_rejected() {
    use mqtt_controller::config::MotionTarget;
    let mut overlap = config();
    let mut second = overlap.motion_rules[0].clone();
    second.name = "other".into();
    overlap.motion_rules.push(second);
    assert!(
        Topology::build(&overlap)
            .unwrap_err()
            .to_string()
            .contains("also targeted")
    );
    let mut missing_slot = config();
    missing_slot.motion_rules[0]
        .targets_by_slot
        .remove("morning");
    assert!(
        Topology::build(&missing_slot)
            .unwrap_err()
            .to_string()
            .contains("exactly")
    );
    let mut unknown_light = config();
    unknown_light.motion_rules[0].targets_by_slot.insert(
        "day".into(),
        MotionTarget::Lights {
            lights: vec!["ghost/11".into()],
        },
    );
    assert!(
        Topology::build(&unknown_light)
            .unwrap_err()
            .to_string()
            .contains("unknown light")
    );
    assert!(
        serde_json::from_value::<MotionTarget>(json!({"group":"bathroom", "lights":["wall/11"]}))
            .is_err()
    );
}

#[test]
fn group_echo_does_not_confirm_individual_targets() {
    use mqtt_controller::tass::TargetPhase;
    let (mut p, _, clock) = processor(config(), 23);
    p.handle_event(occupancy(&clock, true));
    p.handle_event(Event::GroupState {
        group: "bathroom-all".into(),
        on: true,
        ts: clock.now(),
    });
    assert_eq!(
        p.world().lights["wall"].target.phase(),
        TargetPhase::Commanded
    );
    assert!(!p.world().lights.contains_key("ceiling"));
    p.handle_event(Event::LightState {
        device: "wall".into(),
        on: true,
        brightness: Some(160),
        color_temp: Some(454),
        color_xy: None,
        ts: clock.now(),
    });
    assert_eq!(
        p.world().lights["wall"].target.phase(),
        TargetPhase::Confirmed
    );
}

#[test]
#[ignore = "set MQTT_CONTROLLER_CONFIG to a rendered Nix configuration"]
fn rendered_configuration_builds_topology() {
    let path = std::env::var_os("MQTT_CONTROLLER_CONFIG").expect("MQTT_CONTROLLER_CONFIG");
    let cfg: Config = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    Topology::build(&cfg).unwrap();
}

#[test]
fn vacancy_clears_active_motion_badge() {
    let (mut p, _, clock) = processor(config(), 23);
    p.handle_event(occupancy(&clock, true));
    p.handle_event(occupancy(&clock, false));
    let room =
        mqtt_controller::web::snapshot::build_room_snapshot(&p, "bathroom", clock.now()).unwrap();
    assert!(!room.motion_owned);
    assert!(room.motion_rules[0].session_targets.is_empty());
}

mod common;

#[tokio::test]
async fn daemon_publishes_wall_commands_to_endpoint_topic() {
    let broker = common::TestBroker::start().await;
    let client = common::TestClient::connect(&broker, "motion-rule-observer").await;
    for topic in [
        "zigbee2mqtt/wall/11/set",
        "zigbee2mqtt/ceiling/11/set",
        "zigbee2mqtt/bathroom-all/set",
    ] {
        client.subscribe(topic).await;
    }
    let clock = Arc::new(FakeClock::new(23));
    let shutdown = common::spawn_daemon(config(), &broker, clock.clone());
    tokio::time::sleep(Duration::from_millis(250)).await;
    client
        .publish(
            "zigbee2mqtt/sensor",
            r#"{"occupancy":true,"illuminance":0}"#,
        )
        .await;
    let on = client
        .inbox
        .wait_for("zigbee2mqtt/wall/11/set", 1, Duration::from_secs(3))
        .await;
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&on[0]).unwrap(),
        json!({"state":"ON", "brightness":160, "color_temp":454, "transition":0.5})
    );
    clock.set_hour(12);
    client
        .publish(
            "zigbee2mqtt/sensor",
            r#"{"occupancy":false,"illuminance":0}"#,
        )
        .await;
    let off = client
        .inbox
        .wait_for("zigbee2mqtt/wall/11/set", 2, Duration::from_secs(3))
        .await;
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&off[1]).unwrap(),
        json!({"state":"OFF", "transition":0.8})
    );
    assert_eq!(client.inbox.count("zigbee2mqtt/ceiling/11/set").await, 0);
    assert_eq!(client.inbox.count("zigbee2mqtt/bathroom-all/set").await, 0);
    shutdown.send(()).await.unwrap();
}
