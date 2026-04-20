//! Per-mode behaviour tests for the motion dispatcher. One fixture per
//! test; each asserts the exact publish/ownership outcome we expect for
//! the `MotionMode` in play.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::config::scenes::{Scene, SceneSchedule, Slot};
use crate::config::switch_model::{ActionMapping, Gesture, SwitchModel};
use crate::config::{
    Binding, CommonFields, Config, Defaults, DeviceCatalogEntry, Effect as CfgEffect, MotionMode,
    Room, TimeExpr, Trigger as CfgTrigger,
};
use crate::domain::Effect;
use crate::domain::action::Payload;
use crate::domain::event::Event;
use crate::entities::light_zone::{LightZoneActual, LightZoneTarget};
use crate::logic::EventProcessor;
use crate::tass::{ActualFreshness, Owner};
use crate::time::FakeClock;
use crate::topology::Topology;

/// Three-scene day schedule used by every test room.
fn day_scenes() -> SceneSchedule {
    SceneSchedule {
        scenes: vec![
            Scene { id: 1, name: "a".into(), state: "ON".into(), brightness: None, color_temp: None, transition: 0.0 },
            Scene { id: 2, name: "b".into(), state: "ON".into(), brightness: None, color_temp: None, transition: 0.0 },
        ],
        slots: BTreeMap::from([(
            "day".into(),
            Slot {
                from: TimeExpr::Fixed { minute_of_day: 0 },
                to: TimeExpr::Fixed { minute_of_day: 1440 },
                scene_ids: vec![1, 2],
            },
        )]),
    }
}

fn motion_sensor(ieee: &str) -> DeviceCatalogEntry {
    motion_sensor_with(ieee, None)
}

fn motion_sensor_with(ieee: &str, max_illuminance: Option<u32>) -> DeviceCatalogEntry {
    DeviceCatalogEntry::MotionSensor {
        common: CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::new(),
        },
        occupancy_timeout_seconds: 60,
        max_illuminance,
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

fn single_button_model() -> SwitchModel {
    SwitchModel {
        buttons: vec!["on".into()],
        z2m_action_map: BTreeMap::from([(
            "on".into(),
            ActionMapping { button: "on".into(), gesture: Gesture::Press },
        )]),
    }
}

/// Build a processor with one motion-sensor-equipped room in the given mode.
/// Also wires a button-press binding so we can exercise the user-press path.
fn make_processor(mode: MotionMode) -> EventProcessor {
    make_processor_with(mode, None, 0)
}

fn make_processor_with(
    mode: MotionMode,
    max_illuminance: Option<u32>,
    cooldown_secs: u32,
) -> EventProcessor {
    let cfg = Config {
        name_by_address: BTreeMap::new(),
        devices: BTreeMap::from([
            ("hue-l-a".into(), light("0xa")),
            ("hue-ms-room".into(), motion_sensor_with("0xc", max_illuminance)),
            ("hue-s-room".into(), switch_dev("0xd", "single")),
        ]),
        switch_models: BTreeMap::from([("single".into(), single_button_model())]),
        rooms: vec![Room {
            name: "room".into(),
            group_name: "hue-lz-room".into(),
            id: 1,
            members: vec!["hue-l-a/11".into()],
            parent: None,
            motion_sensors: vec!["hue-ms-room".into()],
            scenes: day_scenes(),
            off_transition_seconds: 0.8,
            motion_off_cooldown_seconds: cooldown_secs,
            motion_mode: mode,
        }],
        bindings: vec![Binding {
            name: "room-on".into(),
            trigger: CfgTrigger::Button {
                device: "hue-s-room".into(),
                button: "on".into(),
                gesture: Gesture::Press,
            },
            effect: CfgEffect::SceneToggle { room: "room".into() },
        }],
        defaults: Defaults::default(),
        heating: None,
        location: None,
    };
    let topology = Arc::new(Topology::build(&cfg).expect("build topology"));
    EventProcessor::new(topology, Arc::new(FakeClock::new(12)), Defaults::default(), None)
}

/// Variant of `make_processor` that wires an additional "bedtime"
/// button bound to `TurnOffAllZones`, so we can exercise the global
/// turn-off effect against an off-only zone.
fn make_processor_with_bedtime(mode: MotionMode) -> EventProcessor {
    let cfg = Config {
        name_by_address: BTreeMap::new(),
        devices: BTreeMap::from([
            ("hue-l-a".into(), light("0xa")),
            ("hue-ms-room".into(), motion_sensor("0xc")),
            ("hue-s-room".into(), switch_dev("0xd", "single")),
            ("hue-s-bedtime".into(), switch_dev("0xe", "single")),
        ]),
        switch_models: BTreeMap::from([("single".into(), single_button_model())]),
        rooms: vec![Room {
            name: "room".into(),
            group_name: "hue-lz-room".into(),
            id: 1,
            members: vec!["hue-l-a/11".into()],
            parent: None,
            motion_sensors: vec!["hue-ms-room".into()],
            scenes: day_scenes(),
            off_transition_seconds: 0.8,
            motion_off_cooldown_seconds: 0,
            motion_mode: mode,
        }],
        bindings: vec![
            Binding {
                name: "room-on".into(),
                trigger: CfgTrigger::Button {
                    device: "hue-s-room".into(),
                    button: "on".into(),
                    gesture: Gesture::Press,
                },
                effect: CfgEffect::SceneToggle { room: "room".into() },
            },
            Binding {
                name: "bedtime".into(),
                trigger: CfgTrigger::Button {
                    device: "hue-s-bedtime".into(),
                    button: "on".into(),
                    gesture: Gesture::Press,
                },
                effect: CfgEffect::TurnOffAllZones,
            },
        ],
        defaults: Defaults::default(),
        heating: None,
        location: None,
    };
    let topology = Arc::new(Topology::build(&cfg).expect("build topology"));
    EventProcessor::new(topology, Arc::new(FakeClock::new(12)), Defaults::default(), None)
}

fn occupancy(sensor: &str, occupied: bool, ts: Instant) -> Event {
    Event::Occupancy { sensor: sensor.into(), occupied, illuminance: None, ts }
}

fn occupancy_lux(sensor: &str, occupied: bool, lux: u32, ts: Instant) -> Event {
    Event::Occupancy { sensor: sensor.into(), occupied, illuminance: Some(lux), ts }
}

fn button_press(device: &str, button: &str, ts: Instant) -> Event {
    Event::ButtonPress {
        device: device.into(),
        button: button.into(),
        gesture: Gesture::Press,
        ts,
    }
}

fn expect_scene_recall(effects: &[Effect], scene: u8) {
    let matched = effects.iter().any(|e| matches!(
        e,
        Effect::PublishGroupSet { payload, .. } if payload == &Payload::scene_recall(scene)
    ));
    assert!(matched, "expected scene_recall({scene}) in {effects:?}");
}

fn expect_state_off(effects: &[Effect]) {
    let matched = effects.iter().any(|e| matches!(
        e,
        Effect::PublishGroupSet { payload, .. } if matches!(payload, Payload::StateOff { .. })
    ));
    assert!(matched, "expected state_off in {effects:?}");
}

// ----- on-off (default) -----------------------------------------------------

#[test]
fn on_off_motion_on_turns_on_and_claims_motion_ownership() {
    let mut p = make_processor(MotionMode::OnOff);
    let t0 = Instant::now();

    let effects = p.handle_event(occupancy("hue-ms-room", true, t0));
    expect_scene_recall(&effects, 1);

    let zone = p.world.light_zones.get("room").expect("zone");
    assert_eq!(zone.target.owner(), Some(Owner::Motion));
    assert!(matches!(zone.target.value(), Some(LightZoneTarget::On { .. })));
}

#[test]
fn on_off_motion_off_turns_off_when_motion_owned() {
    let mut p = make_processor(MotionMode::OnOff);
    let t0 = Instant::now();

    let _ = p.handle_event(occupancy("hue-ms-room", true, t0));
    let t1 = t0 + std::time::Duration::from_secs(10);
    let effects = p.handle_event(occupancy("hue-ms-room", false, t1));
    expect_state_off(&effects);
}

// ----- on-only -------------------------------------------------------------

#[test]
fn on_only_motion_on_turns_on_without_claiming_ownership() {
    let mut p = make_processor(MotionMode::OnOnly);
    let t0 = Instant::now();

    let effects = p.handle_event(occupancy("hue-ms-room", true, t0));
    expect_scene_recall(&effects, 1);

    let zone = p.world.light_zones.get("room").expect("zone");
    assert_eq!(zone.target.owner(), Some(Owner::User));
    assert!(!zone.is_motion_owned());
}

#[test]
fn on_only_motion_off_is_noop_even_while_lights_on() {
    let mut p = make_processor(MotionMode::OnOnly);
    let t0 = Instant::now();

    let _ = p.handle_event(occupancy("hue-ms-room", true, t0));
    let t1 = t0 + std::time::Duration::from_secs(10);
    let effects = p.handle_event(occupancy("hue-ms-room", false, t1));
    assert!(
        effects.is_empty(),
        "on-only motion-off must not emit any effects, got {effects:?}"
    );
}

// ----- off-only ------------------------------------------------------------

#[test]
fn off_only_motion_on_claims_ownership_without_turning_on() {
    let mut p = make_processor(MotionMode::OffOnly);
    let t0 = Instant::now();

    let effects = p.handle_event(occupancy("hue-ms-room", true, t0));
    assert!(
        effects.is_empty(),
        "off-only motion-on must NOT publish anything, got {effects:?}"
    );

    let zone = p.world.light_zones.get("room").expect("zone");
    assert_eq!(zone.target.owner(), Some(Owner::Motion));
    assert!(zone.is_motion_owned(), "zone should be motion-owned after off-only motion-on");
}

#[test]
fn off_only_user_press_preserves_motion_ownership_and_lights_up() {
    let mut p = make_processor(MotionMode::OffOnly);
    let t0 = Instant::now();

    let _ = p.handle_event(occupancy("hue-ms-room", true, t0));
    let t1 = t0 + std::time::Duration::from_secs(1);
    let effects = p.handle_event(button_press("hue-s-room", "on", t1));
    expect_scene_recall(&effects, 1);

    let zone = p.world.light_zones.get("room").expect("zone");
    assert_eq!(
        zone.target.owner(),
        Some(Owner::Motion),
        "user press in off-only must not revoke motion ownership",
    );
    assert!(matches!(zone.target.value(), Some(LightZoneTarget::On { .. })));
}

#[test]
fn off_only_motion_clear_after_user_press_turns_off() {
    let mut p = make_processor(MotionMode::OffOnly);
    let t0 = Instant::now();

    let _ = p.handle_event(occupancy("hue-ms-room", true, t0));
    let t1 = t0 + std::time::Duration::from_secs(1);
    let _ = p.handle_event(button_press("hue-s-room", "on", t1));

    let t2 = t1 + std::time::Duration::from_secs(10);
    let effects = p.handle_event(occupancy("hue-ms-room", false, t2));
    expect_state_off(&effects);
}

#[test]
fn off_only_user_press_without_motion_is_plain_user_owned() {
    // Regression: off-only must not make EVERY press motion-owned. Only
    // when motion has already claimed the zone should ownership persist.
    let mut p = make_processor(MotionMode::OffOnly);
    let t0 = Instant::now();

    let effects = p.handle_event(button_press("hue-s-room", "on", t0));
    expect_scene_recall(&effects, 1);
    let zone = p.world.light_zones.get("room").expect("zone");
    assert_eq!(zone.target.owner(), Some(Owner::User));
    assert!(!zone.is_motion_owned());
}

// ----- off-only: review follow-ups -----------------------------------------

/// Codex review (high): a brief walk-through must not latch a motion
/// claim that then hijacks a later manual turn-on.
///
/// We seed the group state as Off first so that the motion-off path
/// takes the "lights confirmed off" branch (release without publish)
/// instead of the "unknown actual" branch (defensive state_off).
#[test]
fn off_only_vacancy_releases_latched_claim_when_lights_off() {
    let mut p = make_processor(MotionMode::OffOnly);
    let t0 = Instant::now();

    // Seed: lights known to be off before the motion session starts.
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: false,
        ts: t0,
    });

    let _ = p.handle_event(occupancy("hue-ms-room", true, t0));
    assert_eq!(
        p.world.light_zones.get("room").unwrap().target.owner(),
        Some(Owner::Motion),
        "motion-on should claim",
    );

    // Walk back out without ever turning lights on. In the broken world
    // the Motion claim would stay latched forever.
    let t1 = t0 + Duration::from_secs(10);
    let effects = p.handle_event(occupancy("hue-ms-room", false, t1));
    assert!(effects.is_empty(), "no off command expected: {effects:?}");
    let zone = p.world.light_zones.get("room").unwrap();
    assert!(
        !zone.is_motion_owned(),
        "vacancy with lights-off in off-only must release the latched Motion claim",
    );

    // A manual press much later is plain user-owned — not Motion.
    let t2 = t1 + Duration::from_secs(600);
    let _ = p.handle_event(button_press("hue-s-room", "on", t2));
    let zone = p.world.light_zones.get("room").unwrap();
    assert_eq!(zone.target.owner(), Some(Owner::User));
}

/// Codex review (high) follow-up: once the claim is released, a transient
/// peripheral occupancy blip must NOT be able to turn off the user's
/// manual activation — because there's no motion-owned zone to turn off.
#[test]
fn off_only_released_claim_not_reinstated_by_stray_vacancy_transition() {
    let mut p = make_processor(MotionMode::OffOnly);
    let t0 = Instant::now();

    // Seed: lights known to be off so the vacancy release can take the
    // "lights confirmed off" branch instead of the defensive state_off
    // for Unknown actual.
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: false,
        ts: t0,
    });

    // Earlier walk-through: claim + release.
    let _ = p.handle_event(occupancy("hue-ms-room", true, t0));
    let _ = p.handle_event(occupancy("hue-ms-room", false, t0 + Duration::from_secs(5)));

    // Hours later: user manually turns the room on.
    let tu = t0 + Duration::from_secs(3600);
    let _ = p.handle_event(button_press("hue-s-room", "on", tu));
    let zone = p.world.light_zones.get("room").unwrap();
    assert_eq!(zone.target.owner(), Some(Owner::User));
    assert!(zone.is_on());

    // A passer-by trips the sensor briefly. Motion-on re-claims Motion
    // (takeover is intentional: "user cannot override motion rules"),
    // and when they leave, the room is auto-offed. This documents the
    // existing semantic — the important part for this test is that the
    // off only fires after a FRESH occupancy session, not from the
    // stale claim.
    let ts1 = tu + Duration::from_secs(60);
    let _ = p.handle_event(occupancy("hue-ms-room", true, ts1));
    let ts2 = ts1 + Duration::from_secs(5);
    let effects = p.handle_event(occupancy("hue-ms-room", false, ts2));
    expect_state_off(&effects);
}

/// Codex review (medium): bright-room luminance gate must also suppress
/// the off-only claim, matching on-off semantics for "don't engage
/// motion automation in bright rooms".
#[test]
fn off_only_luminance_gate_suppresses_claim() {
    let mut p = make_processor_with(MotionMode::OffOnly, Some(50), 0);
    let t0 = Instant::now();

    let _ = p.handle_event(occupancy_lux("hue-ms-room", true, 200, t0));
    let zone = p.world.light_zones.get("room");
    assert!(
        zone.map_or(true, |z| !z.is_motion_owned()),
        "bright room motion-on in off-only must not claim motion ownership",
    );
}

/// Codex review (medium): post-off cooldown must also suppress the
/// off-only claim. After a realistic motion-driven cycle (with
/// z2m echoes), re-entering within the cooldown window must leave the
/// zone's ownership at `System` — the gate refuses to re-claim.
#[test]
fn off_only_cooldown_gate_suppresses_claim() {
    let mut p = make_processor_with(MotionMode::OffOnly, None, 30);
    let t0 = Instant::now();

    // Drive a complete motion-on → user-on → motion-off cycle that
    // settles to Off/System in production: include the z2m ON and OFF
    // echoes so `handle_group_state` clears the motion claim naturally.
    let _ = p.handle_event(occupancy("hue-ms-room", true, t0));
    let _ = p.handle_event(button_press(
        "hue-s-room",
        "on",
        t0 + Duration::from_millis(500),
    ));
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: true,
        ts: t0 + Duration::from_secs(1),
    });
    let _ = p.handle_event(occupancy(
        "hue-ms-room",
        false,
        t0 + Duration::from_secs(5),
    ));
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: false,
        ts: t0 + Duration::from_secs(6),
    });
    let zone = p.world.light_zones.get("room").unwrap();
    assert!(zone.last_off_at.is_some(), "sanity: last_off_at seeded");
    assert_eq!(
        zone.target.owner(),
        Some(Owner::System),
        "sanity: post-cycle ownership is System",
    );

    // Re-enter well inside the 30s cooldown — claim must be suppressed,
    // and owner must stay System (no re-claim to Motion).
    let tc = t0 + Duration::from_secs(10);
    let _ = p.handle_event(occupancy("hue-ms-room", true, tc));
    assert_eq!(
        p.world.light_zones.get("room").unwrap().target.owner(),
        Some(Owner::System),
        "cooldown-suppressed motion-on must not re-claim Motion",
    );
}

// ----- startup-at-retained-ON behaviour -----------------------------------

fn seed_actual_on(p: &mut EventProcessor, room: &str, ts: Instant) {
    let zone = p.world.light_zone(room);
    zone.actual.update(LightZoneActual::On, ts);
}

/// Codex review (medium): on-only rooms must NOT be forcibly turned off
/// at daemon startup. Motion in on-only never commands off; discarding
/// retained state there would create unsolicited state changes on every
/// restart.
#[test]
fn startup_leaves_on_only_retained_state_untouched() {
    let mut p = make_processor(MotionMode::OnOnly);
    let t0 = Instant::now();
    seed_actual_on(&mut p, "room", t0);

    let effects = p.startup_turn_off_motion_zones(t0);
    assert!(
        effects.is_empty(),
        "on-only motion-equipped room must not be forced off at startup: {effects:?}",
    );
    let zone = p.world.light_zones.get("room").unwrap();
    assert!(zone.actual_is_on(), "actual state should be preserved");
}

/// Codex review round 13: a daemon restart while someone is in the
/// room must not silently kill the off-only auto-off guarantee for
/// that session. When any bound sensor is seeded occupied, startup
/// adopts `Motion + On` ownership so the first live vacancy still
/// authorises state_off — even if the user pressed the button during
/// the uncertain window without ever generating a new `occupied=true`
/// edge.
#[test]
fn startup_off_only_adopts_motion_when_seeded_occupied() {
    let mut p = make_processor(MotionMode::OffOnly);
    let t0 = Instant::now();

    seed_actual_on(&mut p, "room", t0);
    let _ = p.handle_event(occupancy("hue-ms-room", true, t0));
    assert!(
        p.world
            .motion_sensors
            .get("hue-ms-room")
            .unwrap()
            .is_occupied(),
        "sanity: seed delivered occupied=true",
    );

    let effects = p.startup_turn_off_motion_zones(t0 + Duration::from_secs(1));
    assert!(
        effects.is_empty(),
        "seeded-occupied off-only zone must not force-off at startup: {effects:?}",
    );
    let zone = p.world.light_zones.get("room").unwrap();
    assert_eq!(zone.target.owner(), Some(Owner::Motion));
    assert!(zone.actual_is_on(), "actual remains On — startup must not fabricate Off");

    // User presses ON during the uncertain window — must stay Motion.
    let _ = p.handle_event(button_press("hue-s-room", "on", t0 + Duration::from_secs(10)));
    assert_eq!(
        p.world.light_zones.get("room").unwrap().target.owner(),
        Some(Owner::Motion),
        "user press during uncertain window must preserve motion ownership",
    );

    // Later live vacancy fires state_off as advertised by off-only.
    let effects = p.handle_event(occupancy(
        "hue-ms-room",
        false,
        t0 + Duration::from_secs(600),
    ));
    expect_state_off(&effects);
}

/// Sibling case: if all bound sensors report vacant at seed, the room
/// is treated as empty and force-offed. Avoids leaving a physically-on
/// room lit forever while the daemon waits for a live event.
#[test]
fn startup_forces_off_off_only_when_all_sensors_seeded_vacant() {
    let mut p = make_processor(MotionMode::OffOnly);
    let t0 = Instant::now();

    seed_actual_on(&mut p, "room", t0);
    let _ = p.handle_event(occupancy("hue-ms-room", false, t0));

    let effects = p.startup_turn_off_motion_zones(t0);
    expect_state_off(&effects);
}

/// Codex adversarial review (high): the startup fail-safe off path
/// used to arm the motion cooldown via the echo handler's `last_off_at`
/// write. If an MQTT retained `group_state=on` arrived during
/// `refresh_state` and processed before the startup OFF echo, the
/// off-transition branch of `handle_group_state` would set
/// `last_off_at`, and the next live `occupied=true` would be cooldown-
/// suppressed — losing the off-only session for the entire cooldown
/// window. The fix splits the cooldown signal from the generic "last
/// off" timestamp: only motion-driven offs arm `last_motion_off_at`,
/// which is what the cooldown gate reads.
#[test]
fn off_only_startup_echo_race_does_not_arm_cooldown() {
    let mut p = make_processor_with(MotionMode::OffOnly, None, 30);
    let t0 = Instant::now();

    // Drive the startup sequence for a physically-on off-only room:
    // seed group_state=On (retained), seed occupancy=false (sensor
    // vacant), startup fail-safe off.
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: true,
        ts: t0,
    });
    let _ = p.handle_event(occupancy("hue-ms-room", false, t0));
    let effects = p.startup_turn_off_motion_zones(t0 + Duration::from_millis(1));
    expect_state_off(&effects);

    // Now simulate the echo of our own state_off arriving — the
    // order-of-events race the reviewer flagged. Before the fix this
    // set `last_off_at` and tripped cooldown.
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: false,
        ts: t0 + Duration::from_millis(50),
    });

    // A live `occupied=true` arrives inside the would-be cooldown
    // window. The motion claim must land — startup-off doesn't arm
    // the motion cooldown.
    let _ = p.handle_event(occupancy("hue-ms-room", true, t0 + Duration::from_secs(1)));
    let zone = p.world.light_zones.get("room").unwrap();
    assert!(
        zone.is_motion_owned(),
        "startup-echo race must not arm cooldown; live occupancy must claim Motion",
    );
}

/// Subagent round 3: a parent in `OnOff` mode propagating motion-on
/// to its descendants must NOT clobber an off-only child's live
/// motion claim. Without the `off_only_session_live` preserve-motion
/// check in `propagate_to_descendants`, the parent's motion-on writes
/// `Owner::System` to the child, the child's subsequent vacancy fails
/// the `is_motion_owned()` gate, and the child stays lit.
#[test]
fn propagation_preserves_off_only_child_motion_claim() {
    let cfg = Config {
        name_by_address: BTreeMap::new(),
        devices: BTreeMap::from([
            ("hue-l-parent".into(), light("0xa")),
            ("hue-l-child".into(), light("0xb")),
            ("hue-ms-parent".into(), motion_sensor("0xc")),
            ("hue-ms-child".into(), motion_sensor("0xd")),
        ]),
        switch_models: BTreeMap::new(),
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
                motion_mode: MotionMode::OnOff,
            },
            Room {
                name: "child".into(),
                group_name: "hue-lz-child".into(),
                id: 2,
                members: vec!["hue-l-child/11".into()],
                parent: Some("parent".into()),
                motion_sensors: vec!["hue-ms-child".into()],
                scenes: day_scenes(),
                off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
                motion_mode: MotionMode::OffOnly,
            },
        ],
        bindings: vec![],
        defaults: Defaults::default(),
        heating: None,
        location: None,
    };
    let topology = Arc::new(Topology::build(&cfg).expect("build topology"));
    let mut p =
        EventProcessor::new(topology, Arc::new(FakeClock::new(12)), Defaults::default(), None);

    let t0 = Instant::now();

    // Establish a live off-only session in the child.
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-child".into(),
        on: false,
        ts: t0,
    });
    let _ = p.handle_event(occupancy("hue-ms-child", true, t0));
    assert!(p.world.light_zones.get("child").unwrap().is_motion_owned());

    // Parent fires motion-on. Its dispatch path propagates to the
    // child. Before the fix, this overwrote the child's target to
    // System-owned, killing the session.
    let _ = p.handle_event(occupancy("hue-ms-parent", true, t0 + Duration::from_secs(1)));

    let child = p.world.light_zones.get("child").unwrap();
    assert_eq!(
        child.target.owner(),
        Some(Owner::Motion),
        "off-only child must keep Motion ownership across parent propagation",
    );

    // Child's own vacancy must still authorise state_off even though
    // the parent claimed motion-on concurrently.
    let effects =
        p.handle_event(occupancy("hue-ms-child", false, t0 + Duration::from_secs(30)));
    expect_state_off(&effects);
}

/// Codex review round 14: a sensor bound to multiple rooms must fan a
/// single `occupied=false` transition out to EVERY bound room's
/// motion-off path. Previously `dispatch_motion` re-read `prev_occupied`
/// after the first iteration's actual-state update, so only the first
/// room saw the real transition and subsequent rooms dedup'd.
#[test]
fn shared_motion_sensor_fans_vacancy_to_all_rooms() {
    use crate::entities::light_zone::LightZoneActual;

    // Build a two-room topology with one shared sensor.
    let cfg = Config {
        name_by_address: BTreeMap::new(),
        devices: BTreeMap::from([
            ("hue-l-a".into(), light("0xa")),
            ("hue-l-b".into(), light("0xb")),
            ("hue-ms-shared".into(), motion_sensor("0xc")),
        ]),
        switch_models: BTreeMap::new(),
        rooms: vec![
            Room {
                name: "room-a".into(),
                group_name: "hue-lz-a".into(),
                id: 1,
                members: vec!["hue-l-a/11".into()],
                parent: None,
                motion_sensors: vec!["hue-ms-shared".into()],
                scenes: day_scenes(),
                off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
                motion_mode: MotionMode::OnOff,
            },
            Room {
                name: "room-b".into(),
                group_name: "hue-lz-b".into(),
                id: 2,
                members: vec!["hue-l-b/11".into()],
                parent: None,
                motion_sensors: vec!["hue-ms-shared".into()],
                scenes: day_scenes(),
                off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
                motion_mode: MotionMode::OnOff,
            },
        ],
        bindings: vec![],
        defaults: Defaults::default(),
        heating: None,
        location: None,
    };
    let topology = Arc::new(Topology::build(&cfg).expect("build topology"));
    let mut p =
        EventProcessor::new(topology, Arc::new(FakeClock::new(12)), Defaults::default(), None);

    let t0 = Instant::now();

    // Motion-on: both rooms get scene_recall and become motion-owned.
    let on_effects = p.handle_event(occupancy("hue-ms-shared", true, t0));
    assert_eq!(
        on_effects.iter().filter(|e| matches!(
            e,
            Effect::PublishGroupSet { payload, .. }
                if matches!(payload, Payload::SceneRecall { .. })
        )).count(),
        2,
        "both rooms should receive scene_recall: {on_effects:?}",
    );
    // Force actual=On on both zones so the later is_on check sees them.
    p.world.light_zone("room-a").actual.update(LightZoneActual::On, t0);
    p.world.light_zone("room-b").actual.update(LightZoneActual::On, t0);
    assert!(p.world.light_zones.get("room-a").unwrap().is_motion_owned());
    assert!(p.world.light_zones.get("room-b").unwrap().is_motion_owned());

    // Motion-off: both rooms must fire state_off. Before the fix, only
    // room-a would — the second iteration dedup'd.
    let off_effects =
        p.handle_event(occupancy("hue-ms-shared", false, t0 + Duration::from_secs(10)));
    let state_off_count = off_effects
        .iter()
        .filter(|e| matches!(
            e,
            Effect::PublishGroupSet { payload, .. }
                if matches!(payload, Payload::StateOff { .. })
        ))
        .count();
    assert_eq!(
        state_off_count, 2,
        "both shared-sensor rooms must receive state_off on a single vacancy transition: {off_effects:?}",
    );
}

/// Regression: the startup auto-off still fires for the classic on-off
/// motion-equipped room (the historical behaviour we want to keep).
#[test]
fn startup_still_turns_off_on_off_motion_rooms() {
    let mut p = make_processor(MotionMode::OnOff);
    let t0 = Instant::now();
    seed_actual_on(&mut p, "room", t0);

    let effects = p.startup_turn_off_motion_zones(t0);
    expect_state_off(&effects);
}

// ----- off-only target healing at motion-on --------------------------------

/// Codex follow-up review (high): a stale `On` target (command timed
/// out without an echo → `TargetPhase::Stale`) must be healed to match
/// actual before the off-only motion claim, or the next SceneToggle
/// press will take the OFF branch even though the lights are
/// physically off.
#[test]
fn off_only_heals_stale_on_target_when_actual_is_off() {
    let mut p = make_processor(MotionMode::OffOnly);
    let t0 = Instant::now();

    // Simulate a stale On target: earlier user press, command lost,
    // periodic staleness sweep demoted phase to Stale.
    {
        let zone = p.world.light_zone("room");
        zone.target.set_and_command(
            LightZoneTarget::On { scene_id: 7, cycle_idx: 3 },
            Owner::User,
            t0,
        );
        zone.target.mark_stale();
        // actual remains Unknown — reads as !actual_is_on().
    }

    let _ = p.handle_event(occupancy("hue-ms-room", true, t0 + Duration::from_secs(1)));

    let zone = p.world.light_zones.get("room").unwrap();
    assert_eq!(
        zone.target.owner(),
        Some(Owner::Motion),
        "motion should have taken ownership"
    );
    assert!(
        !zone.target_is_on(),
        "stale On target must be healed to Off (actual was Off)"
    );
    assert!(!zone.is_on(), "is_on() must now return false");
}

/// Coherent case: a live user press that has already been echoed
/// (actual=On, target=On/Confirmed) must preserve scene_id /
/// cycle_idx through the motion takeover so the next SceneCycle
/// continues from where the user left off.
#[test]
fn off_only_preserves_cycle_state_when_target_matches_actual() {
    let mut p = make_processor(MotionMode::OffOnly);
    let t0 = Instant::now();

    {
        let zone = p.world.light_zone("room");
        zone.target.set_and_command(
            LightZoneTarget::On { scene_id: 7, cycle_idx: 3 },
            Owner::User,
            t0,
        );
        zone.actual.update(LightZoneActual::On, t0);
        // Confirm like handle_group_state would on the echo.
        zone.target.confirm(t0);
    }

    let _ = p.handle_event(occupancy("hue-ms-room", true, t0 + Duration::from_secs(1)));

    let zone = p.world.light_zones.get("room").unwrap();
    assert_eq!(zone.target.owner(), Some(Owner::Motion));
    match zone.target.value() {
        Some(LightZoneTarget::On { scene_id: 7, cycle_idx: 3 }) => {}
        other => panic!("scene_id / cycle_idx must be preserved, got {other:?}"),
    }
}

/// In-flight user press (phase=Commanded, no echo yet) must NOT be
/// healed by an off-only motion-on firing mid-command — that would
/// race the user's press and drop it. The claim is a pure owner
/// handover; the pending command and its scene/cycle ride along.
#[test]
fn off_only_does_not_heal_in_flight_commanded_target() {
    let mut p = make_processor(MotionMode::OffOnly);
    let t0 = Instant::now();

    {
        let zone = p.world.light_zone("room");
        zone.target.set_and_command(
            LightZoneTarget::On { scene_id: 7, cycle_idx: 3 },
            Owner::User,
            t0,
        );
        // actual is still Unknown (command in flight).
    }

    let _ = p.handle_event(occupancy("hue-ms-room", true, t0 + Duration::from_secs(1)));

    let zone = p.world.light_zones.get("room").unwrap();
    assert_eq!(zone.target.owner(), Some(Owner::Motion));
    match zone.target.value() {
        Some(LightZoneTarget::On { scene_id: 7, cycle_idx: 3 }) => {}
        other => panic!("in-flight scene/cycle must survive claim, got {other:?}"),
    }
}

/// Stale-Off target + actual=On (e.g. z2m was power-cycled while an
/// earlier System-owned Off was in flight, and the controller then
/// observed lights come back on some other way) must heal to
/// On{0,0}/Motion so motion-off can later authorise the off.
#[test]
fn off_only_heals_stale_off_target_when_actual_is_on() {
    let mut p = make_processor(MotionMode::OffOnly);
    let t0 = Instant::now();

    {
        let zone = p.world.light_zone("room");
        zone.target.set_and_command(LightZoneTarget::Off, Owner::System, t0);
        zone.target.mark_stale();
        zone.actual.update(LightZoneActual::On, t0);
    }

    let _ = p.handle_event(occupancy("hue-ms-room", true, t0 + Duration::from_secs(1)));

    let zone = p.world.light_zones.get("room").unwrap();
    assert_eq!(zone.target.owner(), Some(Owner::Motion));
    assert!(
        zone.target_is_on(),
        "stale Off target must be healed to On when actual reports on"
    );
}

/// Codex follow-up review (high): repeated `occupied=true` publishes in
/// off-only rooms re-enter `dispatch_motion_on` and hand ownership over
/// to Motion each time. If that handover refreshed the target's `since`
/// field, a dropped user command would never mature to `Stale` — the
/// staleness sweep is time-since-command and we must not keep resetting
/// it on every occupancy repeat.
#[test]
fn off_only_claim_preserves_since_for_in_flight_commanded_target() {
    let mut p = make_processor(MotionMode::OffOnly);
    let t0 = Instant::now();

    // Pretend a user scene_recall is in flight: Commanded, no echo yet.
    {
        let zone = p.world.light_zone("room");
        zone.target.set_and_command(
            LightZoneTarget::On { scene_id: 7, cycle_idx: 3 },
            Owner::User,
            t0,
        );
    }
    let since_before = p.world.light_zones.get("room").unwrap().target.since();

    // Several occupancy re-publishes — each triggers a Motion claim
    // that handovers ownership via reassign_owner.
    for dt_secs in [3u64, 5, 8] {
        let _ = p.handle_event(occupancy(
            "hue-ms-room",
            true,
            t0 + Duration::from_secs(dt_secs),
        ));
    }

    let zone = p.world.light_zones.get("room").unwrap();
    assert_eq!(
        zone.target.owner(),
        Some(Owner::Motion),
        "ownership should have handed over to Motion",
    );
    match zone.target.value() {
        Some(LightZoneTarget::On { scene_id: 7, cycle_idx: 3 }) => {}
        other => panic!("in-flight scene/cycle must survive owner handover, got {other:?}"),
    }
    assert_eq!(
        zone.target.since(),
        since_before,
        "Commanded `since` must be preserved across motion owner handovers so staleness sweep still works",
    );

    // Advance 11s past the original command. The staleness sweep can
    // now promote the Commanded target to Stale because `since` was
    // anchored to t0, not to any of the later occupancy events.
    let now_stale = t0 + Duration::from_secs(11);
    let became_stale = p
        .world
        .light_zone("room")
        .target
        .mark_stale_if_old(now_stale, Duration::from_secs(10));
    assert!(
        became_stale,
        "target must become Stale 10s after the original command, independent of occupancy re-publishes",
    );
}

/// Codex review (P2): a manual OFF → ON cycle inside a single
/// occupancy session must NOT defeat the off-only auto-off. The fix
/// lives in `handle_group_state`: on the OFF echo, if the zone is
/// currently motion-owned and a bound sensor is still occupied, we
/// preserve `Owner::Motion` instead of the generic reset to
/// `Owner::System`. That keeps `resolve_zone_owner` trivial (it can
/// just check the zone owner) and avoids re-arming sessions where the
/// lux/cooldown gate deliberately suppressed the original claim.
#[test]
fn off_only_user_off_then_on_within_session_preserves_motion_claim() {
    let mut p = make_processor(MotionMode::OffOnly);
    let t0 = Instant::now();

    // Sensor reports occupancy → motion claim.
    let _ = p.handle_event(occupancy("hue-ms-room", true, t0));
    assert!(p.world.light_zones.get("room").unwrap().is_motion_owned());

    // User turns ON during the session.
    let _ = p.handle_event(button_press("hue-s-room", "on", t0 + Duration::from_secs(1)));
    // z2m echoes the ON transition.
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: true,
        ts: t0 + Duration::from_millis(1_500),
    });
    assert_eq!(
        p.world.light_zones.get("room").unwrap().target.owner(),
        Some(Owner::Motion),
        "ON press during session keeps Motion ownership",
    );

    // User turns OFF during the same session. After the echo,
    // handle_group_state's off-only-session preservation must keep
    // Motion ownership intact (sensor still occupied, zone was
    // motion-owned at echo time).
    let _ = p.handle_event(button_press("hue-s-room", "on", t0 + Duration::from_secs(2)));
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: false,
        ts: t0 + Duration::from_millis(2_500),
    });
    assert_eq!(
        p.world.light_zones.get("room").unwrap().target.owner(),
        Some(Owner::Motion),
        "off-only OFF echo with active session must preserve Motion ownership",
    );

    // User turns ON again.
    let _ = p.handle_event(button_press("hue-s-room", "on", t0 + Duration::from_secs(3)));
    let zone = p.world.light_zones.get("room").unwrap();
    assert_eq!(zone.target.owner(), Some(Owner::Motion));
    assert!(zone.is_motion_owned());

    // When the user finally leaves, motion-off fires.
    let effects = p.handle_event(occupancy(
        "hue-ms-room",
        false,
        t0 + Duration::from_secs(60),
    ));
    expect_state_off(&effects);
}

/// Stop-hook review: the lux gate must not be backdoored. If
/// illuminance is above the sensor's max, no motion claim is made;
/// the user's manual on/off presses must stay user-owned end-to-end
/// and a later vacancy transition must NOT auto-off the room.
#[test]
fn off_only_lux_suppressed_session_stays_user_owned_end_to_end() {
    let mut p = make_processor_with(MotionMode::OffOnly, Some(50), 0);
    let t0 = Instant::now();

    // Bright room, sensor occupied — lux gate suppresses the claim.
    // The off-only fast path returns before ever touching the zone, so
    // the zone entry may not exist yet; "not motion-owned" here means
    // "no zone or zone owner is not Motion".
    let _ = p.handle_event(occupancy_lux("hue-ms-room", true, 200, t0));
    assert!(
        p.world
            .light_zones
            .get("room")
            .map_or(true, |z| !z.is_motion_owned()),
        "sanity: lux gate should have suppressed the motion claim"
    );

    // User presses ON — must stay user-owned.
    let _ = p.handle_event(button_press("hue-s-room", "on", t0 + Duration::from_secs(1)));
    assert_eq!(
        p.world.light_zones.get("room").unwrap().target.owner(),
        Some(Owner::User),
        "lux-suppressed session: ON press must remain user-owned",
    );

    // OFF echo under a non-motion-owned zone wipes to System
    // (unchanged behaviour) — the preservation branch requires a
    // pre-existing Motion claim.
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: true,
        ts: t0 + Duration::from_millis(1_500),
    });
    let _ = p.handle_event(button_press("hue-s-room", "on", t0 + Duration::from_secs(2)));
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: false,
        ts: t0 + Duration::from_millis(2_500),
    });
    assert_eq!(
        p.world.light_zones.get("room").unwrap().target.owner(),
        Some(Owner::System),
    );

    // User re-presses ON — still user-owned (no sensor-fallback
    // backdoor to Motion).
    let _ = p.handle_event(button_press("hue-s-room", "on", t0 + Duration::from_secs(3)));
    assert_eq!(
        p.world.light_zones.get("room").unwrap().target.owner(),
        Some(Owner::User),
        "lux-suppressed session: re-ON must not be promoted to Motion",
    );

    // When the sensor goes vacant, motion-off must NOT fire.
    let effects = p.handle_event(occupancy_lux(
        "hue-ms-room",
        false,
        200,
        t0 + Duration::from_secs(60),
    ));
    assert!(
        effects.is_empty(),
        "vacancy after a lux-suppressed session must not auto-off: {effects:?}",
    );
}

/// Stop-hook review: the cooldown gate must not be backdoored either.
/// Within the post-off cooldown window, motion-on cannot claim, so a
/// user press in that window stays user-owned and the later vacancy
/// does not auto-off.
#[test]
fn off_only_cooldown_suppressed_session_stays_user_owned_end_to_end() {
    let mut p = make_processor_with(MotionMode::OffOnly, None, 30);
    let t0 = Instant::now();

    // Seed `last_off_at` with a complete motion-driven off cycle,
    // including the z2m echoes that normally reset the motion claim
    // to System after the lights go off.
    let _ = p.handle_event(occupancy("hue-ms-room", true, t0));
    let _ = p.handle_event(button_press(
        "hue-s-room",
        "on",
        t0 + Duration::from_millis(500),
    ));
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: true,
        ts: t0 + Duration::from_secs(1),
    });
    let _ = p.handle_event(occupancy(
        "hue-ms-room",
        false,
        t0 + Duration::from_secs(5),
    ));
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: false,
        ts: t0 + Duration::from_secs(6),
    });
    let zone = p.world.light_zones.get("room").unwrap();
    assert!(zone.last_off_at.is_some(), "sanity: last_off_at seeded");
    assert!(
        !zone.is_motion_owned(),
        "sanity: post-motion-off echo releases Motion ownership",
    );

    // Re-enter well inside the cooldown window. Claim must be
    // suppressed; zone stays non-motion-owned.
    let tc = t0 + Duration::from_secs(10);
    let _ = p.handle_event(occupancy("hue-ms-room", true, tc));
    assert!(!p.world.light_zones.get("room").unwrap().is_motion_owned());

    // User press during cooldown must remain user-owned.
    let _ = p.handle_event(button_press("hue-s-room", "on", tc + Duration::from_secs(1)));
    assert_eq!(
        p.world.light_zones.get("room").unwrap().target.owner(),
        Some(Owner::User),
    );

    // Vacancy must not auto-off — user's intent during a
    // cooldown-suppressed session is respected.
    let effects = p.handle_event(occupancy(
        "hue-ms-room",
        false,
        tc + Duration::from_secs(60),
    ));
    assert!(
        effects.is_empty(),
        "cooldown-suppressed session must not auto-off: {effects:?}",
    );
}

// ----- off-only motion-off with degraded actual state ---------------------

/// Codex adversarial review (high): an off-only room may reach motion
/// dispatch before any group state has been observed — e.g. a seed
/// that delivered occupancy but skipped/failed the group state payload.
/// In that case `is_on()` is false even if the room is physically lit.
/// Vacancy MUST still publish `state_off` defensively, otherwise the
/// advertised auto-off is silently dropped for that session.
#[test]
fn off_only_motion_off_fires_state_off_when_actual_is_unknown() {
    let mut p = make_processor(MotionMode::OffOnly);
    let t0 = Instant::now();

    // No GroupState event — actual freshness stays Unknown.
    let _ = p.handle_event(occupancy("hue-ms-room", true, t0));
    let zone = p.world.light_zones.get("room").unwrap();
    assert_eq!(
        zone.actual.freshness(),
        ActualFreshness::Unknown,
        "sanity: actual should be Unknown — no group state was ever delivered",
    );
    assert!(zone.is_motion_owned());

    let effects =
        p.handle_event(occupancy("hue-ms-room", false, t0 + Duration::from_secs(60)));
    expect_state_off(&effects);
}

/// Stop-hook review: a zombie Motion claim combined with a
/// gate-suppressed NEW-session event must not survive. Lux or cooldown
/// suppressing the fresh claim must also clear any latched claim from
/// a past (stale) session, otherwise `resolve_zone_owner` would see
/// "motion-owned + sensor fresh+occupied" and hand Motion back on the
/// next user press — defeating the gate.
#[test]
fn off_only_zombie_claim_cleared_by_gate_suppressed_new_session() {
    let mut p = make_processor_with(MotionMode::OffOnly, Some(50), 0);
    let t0 = Instant::now();

    // Seed lights known off so the initial claim sticks cleanly.
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: false,
        ts: t0,
    });

    // Low-lux motion-on: lux gate does NOT fire, claim succeeds.
    let _ = p.handle_event(occupancy_lux("hue-ms-room", true, 10, t0));
    assert!(
        p.world.light_zones.get("room").unwrap().is_motion_owned(),
        "sanity: low-lux session should have claimed Motion",
    );

    // Sensor ages to Stale without ever sending `false`.
    p.world
        .motion_sensor("hue-ms-room")
        .actual
        .mark_stale();

    // Sensor recovers with a FRESH occupied=true event — but in a now
    // bright room. The lux gate must suppress the new claim AND clear
    // the zombie, so it cannot backdoor `resolve_zone_owner`.
    let tnew = t0 + Duration::from_secs(600);
    let _ = p.handle_event(occupancy_lux("hue-ms-room", true, 200, tnew));
    let zone = p.world.light_zones.get("room").unwrap();
    assert!(
        !zone.is_motion_owned(),
        "gate-suppressed new-session event must release the zombie motion claim",
    );

    // User's manual press stays user-owned, and a subsequent vacancy
    // must not auto-off their session.
    let tp = tnew + Duration::from_secs(5);
    let _ = p.handle_event(button_press("hue-s-room", "on", tp));
    assert_eq!(
        p.world.light_zones.get("room").unwrap().target.owner(),
        Some(Owner::User),
    );
    let effects = p.handle_event(occupancy_lux(
        "hue-ms-room",
        false,
        200,
        tp + Duration::from_secs(600),
    ));
    assert!(
        effects.is_empty(),
        "gate-suppressed session must not auto-off the user's manual press: {effects:?}",
    );
}

/// Subagent review follow-up: in a multi-sensor room where one sensor
/// has gone silent but the zone is still motion-owned with lights
/// physically on (a live session), a gate-suppressed event on another
/// bound sensor must not release the live claim. The zombie-release
/// path is for dark, truly-ended sessions — not live lights.
#[test]
fn off_only_gate_suppressed_new_sensor_does_not_release_live_session() {
    use crate::entities::light_zone::LightZoneActual;

    let mut p = make_processor_with(MotionMode::OffOnly, Some(50), 0);
    let t0 = Instant::now();

    // Seed lights off, claim Motion, user presses ON → live session,
    // lights physically on, motion-owned.
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: false,
        ts: t0,
    });
    let _ = p.handle_event(occupancy_lux("hue-ms-room", true, 10, t0));
    let _ = p.handle_event(button_press("hue-s-room", "on", t0 + Duration::from_secs(1)));
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: true,
        ts: t0 + Duration::from_secs(2),
    });
    let zone = p.world.light_zones.get("room").unwrap();
    assert!(zone.is_motion_owned());
    assert!(zone.actual_is_on());

    // Sensor goes silent and ages to Stale without ever publishing
    // false (real Hue sensors usually publish false after 60s, but
    // message drops or device hiccups can skip that).
    p.world.motion_sensor("hue-ms-room").actual.mark_stale();

    // A new "new-session" motion-on event with lux above the gate.
    // Even though our test fixture has only one bound sensor, the
    // resulting sequence (prev_sensor_was_occupied=false because the
    // sensor is Stale → is_occupied=false) reproduces the condition
    // in a multi-sensor room where a different bound sensor fires.
    let _ = p.handle_event(occupancy_lux(
        "hue-ms-room",
        true,
        200,
        t0 + Duration::from_secs(600),
    ));

    let zone = p.world.light_zones.get("room").unwrap();
    assert!(
        zone.is_motion_owned(),
        "gate-suppressed new-session event must not release a live motion session (zone still actually on)",
    );
}

/// Counter-case: a repeated `occupied=true` publish during an ACTIVE
/// session (Hue sensors re-publish state every ~10s) must not release
/// the motion claim, even if lux has risen above the gate threshold
/// mid-session. The release only fires for new-session events.
#[test]
fn off_only_gate_suppressed_repeat_does_not_clear_active_claim() {
    let mut p = make_processor_with(MotionMode::OffOnly, Some(50), 0);
    let t0 = Instant::now();

    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: false,
        ts: t0,
    });
    let _ = p.handle_event(occupancy_lux("hue-ms-room", true, 10, t0));
    assert!(p.world.light_zones.get("room").unwrap().is_motion_owned());

    // Still-occupied repeat with now-high lux — this is a re-publish of
    // the same session, not a new one.
    let _ = p.handle_event(occupancy_lux(
        "hue-ms-room",
        true,
        200,
        t0 + Duration::from_secs(30),
    ));
    assert!(
        p.world.light_zones.get("room").unwrap().is_motion_owned(),
        "repeat occupied=true during active session must preserve the claim",
    );
}

/// Subagent round 2: a global `TurnOffAllZones` effect (e.g. a bedtime
/// button) that fires while an off-only room still has a live session
/// must not clobber the motion claim. The effect now routes through
/// `resolve_zone_owner`, so an actively-occupied zone keeps
/// `Owner::Motion` and the eventual vacancy still fires state_off.
#[test]
fn off_only_turn_off_all_zones_preserves_live_session() {
    let mut p = make_processor_with_bedtime(MotionMode::OffOnly);
    let t0 = Instant::now();

    // Establish a live session: group=Off seed, motion claim, user ON,
    // echo ON.
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: false,
        ts: t0,
    });
    let _ = p.handle_event(occupancy("hue-ms-room", true, t0));
    let _ = p.handle_event(button_press("hue-s-room", "on", t0 + Duration::from_secs(1)));
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: true,
        ts: t0 + Duration::from_secs(2),
    });
    let zone = p.world.light_zones.get("room").unwrap();
    assert!(zone.is_motion_owned());
    assert!(zone.actual_is_on());

    // Press the bedtime button while the user is still in the room.
    let effects = p.handle_event(button_press(
        "hue-s-bedtime",
        "on",
        t0 + Duration::from_secs(10),
    ));
    expect_state_off(&effects);
    let zone = p.world.light_zones.get("room").unwrap();
    assert_eq!(
        zone.target.owner(),
        Some(Owner::Motion),
        "TurnOffAllZones on a live off-only session must preserve Motion ownership",
    );
    assert!(matches!(zone.target.value(), Some(LightZoneTarget::Off)));
}

/// Contrast: `TurnOffAllZones` in an off-only room with NO live session
/// (sensor vacant) wipes ownership to `Owner::Schedule` as before —
/// the preservation only kicks in for verifiably-live sessions.
#[test]
fn off_only_turn_off_all_zones_wipes_ownership_when_no_live_session() {
    let mut p = make_processor_with_bedtime(MotionMode::OffOnly);
    let t0 = Instant::now();

    // Seed group On with sensor vacant — no motion claim, no active
    // session. Fabricate actual=On so the TurnOffAllZones `if
    // zone.is_on()` branch fires.
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: true,
        ts: t0,
    });
    let _ = p.handle_event(occupancy("hue-ms-room", false, t0));
    assert!(!p.world.light_zones.get("room").unwrap().is_motion_owned());

    let effects = p.handle_event(button_press(
        "hue-s-bedtime",
        "on",
        t0 + Duration::from_secs(1),
    ));
    expect_state_off(&effects);
    assert_eq!(
        p.world.light_zones.get("room").unwrap().target.owner(),
        Some(Owner::Schedule),
        "no-live-session: TurnOffAllZones falls back to Owner::Schedule",
    );
}

/// Codex adversarial review (high): a zombie motion claim must not
/// promote later user presses to Motion. If the sensor that made the
/// claim ages to Stale without ever publishing `occupied=false` (so
/// the vacancy-release path never fires), the zone is still
/// motion-owned — but the session is effectively over. A manual ON
/// press after that must stay user-owned so a later recovered
/// `occupied=false` transition doesn't auto-off the user's session.
#[test]
fn off_only_stale_sensor_does_not_promote_user_press_to_motion() {
    let mut p = make_processor(MotionMode::OffOnly);
    let t0 = Instant::now();

    // Seed lights known off so the initial claim sticks without any
    // spurious state_off publishes later.
    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: false,
        ts: t0,
    });
    let _ = p.handle_event(occupancy("hue-ms-room", true, t0));
    assert!(
        p.world.light_zones.get("room").unwrap().is_motion_owned(),
        "sanity: initial motion-on should have claimed",
    );

    // Simulate the sensor aging to Stale without ever sending `false`
    // (what the periodic staleness sweep would do after the sensor
    // goes silent). The latched `Owner::Motion` on the zone stays
    // because the stale sweep only fires state_off for rooms that are
    // still physically on.
    p.world
        .motion_sensor("hue-ms-room")
        .actual
        .mark_stale();
    assert!(
        !p.world
            .motion_sensors
            .get("hue-ms-room")
            .unwrap()
            .is_occupied(),
        "sanity: a stale sensor must not look occupied",
    );
    assert_eq!(
        p.world.light_zones.get("room").unwrap().target.owner(),
        Some(Owner::Motion),
        "sanity: zombie Motion claim stays latched on the zone",
    );

    // User presses ON long after. The press must be user-owned —
    // without the `any_sensor_occupied` liveness check in
    // `resolve_zone_owner` this would be promoted to Motion via the
    // latched claim and the next live sensor event could auto-off it.
    let tp = t0 + Duration::from_secs(600);
    let _ = p.handle_event(button_press("hue-s-room", "on", tp));
    assert_eq!(
        p.world.light_zones.get("room").unwrap().target.owner(),
        Some(Owner::User),
        "stale-session zombie claim must not promote user press to Motion",
    );

    // Sensor eventually recovers with `occupied=false`. The zone is
    // now user-owned, so motion-off must NOT emit state_off and
    // cancel the user's manual activation.
    let effects = p.handle_event(occupancy(
        "hue-ms-room",
        false,
        tp + Duration::from_secs(60),
    ));
    assert!(
        effects.is_empty(),
        "recovered sensor false must not cancel user's manual session: {effects:?}",
    );
}

/// Contrast: when actual IS known to be Off (group state seeded), the
/// vacancy path still releases the latched claim without publishing —
/// we only publish when we can't confirm the room is off.
#[test]
fn off_only_motion_off_releases_claim_when_actual_confirmed_off() {
    let mut p = make_processor(MotionMode::OffOnly);
    let t0 = Instant::now();

    let _ = p.handle_event(Event::GroupState {
        group: "hue-lz-room".into(),
        on: false,
        ts: t0,
    });
    let _ = p.handle_event(occupancy("hue-ms-room", true, t0));
    let zone = p.world.light_zones.get("room").unwrap();
    assert!(zone.is_motion_owned());

    let effects =
        p.handle_event(occupancy("hue-ms-room", false, t0 + Duration::from_secs(60)));
    assert!(
        effects.is_empty(),
        "confirmed-off vacancy must release without publishing: {effects:?}",
    );
    let zone = p.world.light_zones.get("room").unwrap();
    assert!(!zone.is_motion_owned());
}
