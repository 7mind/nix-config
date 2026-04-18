//! Tests for `scenes`. Split out so `scenes.rs` stays focused on
//! production code. See `scenes.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;
use pretty_assertions::assert_eq;

fn fixed(h: u8, m: u8) -> TimeExpr {
    TimeExpr::Fixed { minute_of_day: h as u16 * 60 + m as u16 }
}

fn day_night_schedule() -> SceneSchedule {
    SceneSchedule {
        scenes: vec![
            Scene {
                id: 1,
                name: "bright".into(),
                state: "ON".into(),
                brightness: Some(254),
                color_temp: Some(250),
                transition: 0.5,
            },
            Scene {
                id: 2,
                name: "relaxed".into(),
                state: "ON".into(),
                brightness: Some(180),
                color_temp: Some(350),
                transition: 0.5,
            },
            Scene {
                id: 3,
                name: "dim".into(),
                state: "ON".into(),
                brightness: Some(60),
                color_temp: Some(500),
                transition: 0.5,
            },
        ],
        slots: BTreeMap::from([
            (
                "day".into(),
                Slot {
                    from: fixed(6, 0),
                    to: fixed(23, 0),
                    scene_ids: vec![1, 2, 3],
                },
            ),
            (
                "night".into(),
                Slot {
                    from: fixed(23, 0),
                    to: fixed(6, 0),
                    scene_ids: vec![3, 2, 1],
                },
            ),
        ]),
    }
}

#[test]
fn day_night_validates_and_resolves() {
    let s = day_night_schedule();
    s.validate().unwrap();

    let (name, slot) = s.slot_for_time(12, 0, None).unwrap();
    assert_eq!(name, "day");
    assert_eq!(slot.scene_ids, vec![1, 2, 3]);

    let (name, _) = s.slot_for_time(23, 0, None).unwrap();
    assert_eq!(name, "night");

    let (name, _) = s.slot_for_time(2, 0, None).unwrap();
    assert_eq!(name, "night");
}

#[test]
fn slot_contains_time_normal_range() {
    let s = Slot {
        from: fixed(6, 0),
        to: fixed(23, 0),
        scene_ids: vec![],
    };
    assert!(!s.contains_time(5, 59, None));
    assert!(s.contains_time(6, 0, None));
    assert!(s.contains_time(22, 59, None));
    assert!(!s.contains_time(23, 0, None));
}

#[test]
fn slot_contains_time_wrap_range() {
    let s = Slot {
        from: fixed(23, 0),
        to: fixed(6, 0),
        scene_ids: vec![],
    };
    assert!(s.contains_time(23, 0, None));
    assert!(s.contains_time(0, 0, None));
    assert!(s.contains_time(5, 59, None));
    assert!(!s.contains_time(6, 0, None));
    assert!(!s.contains_time(22, 59, None));
}

#[test]
fn unknown_scene_id_in_cycle_is_rejected() {
    let mut s = day_night_schedule();
    s.slots.get_mut("day").unwrap().scene_ids = vec![1, 99];
    let err = s.validate().unwrap_err();
    assert!(matches!(
        err,
        SceneScheduleError::UnknownSceneId { id: 99, .. }
    ));
}

#[test]
fn overlapping_slots_are_rejected() {
    let mut s = day_night_schedule();
    // Make night start at 22:00 instead of 23:00 → overlaps with day.
    s.slots.get_mut("night").unwrap().from = fixed(22, 0);
    let err = s.validate().unwrap_err();
    assert!(matches!(
        err,
        SceneScheduleError::OverlappingSlots { .. }
    ));
}

#[test]
fn gap_in_coverage_is_rejected() {
    let s = SceneSchedule {
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
                from: fixed(6, 0),
                to: fixed(22, 0),
                scene_ids: vec![1],
            },
        )]),
    };
    let err = s.validate().unwrap_err();
    assert!(matches!(
        err,
        SceneScheduleError::IncompleteCoverage { .. }
    ));
}

#[test]
fn sun_relative_schedule_skips_coverage_check() {
    use crate::config::time_expr::SunEvent;
    let s = SceneSchedule {
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
                from: TimeExpr::SunRelative { event: SunEvent::Sunrise, offset_minutes: 0 },
                to: TimeExpr::SunRelative { event: SunEvent::Sunset, offset_minutes: 0 },
                scene_ids: vec![1],
            },
        )]),
    };
    // Would fail coverage check, but sun expressions skip it.
    s.validate().unwrap();
}

#[test]
fn serde_roundtrip() {
    let json = r#"{
        "scenes": [
            {"id": 1, "name": "x", "state": "ON", "brightness": null, "color_temp": null, "transition": 0.5}
        ],
        "slots": {
            "day": {"from": "06:00", "to": "23:00", "scene_ids": [1]}
        }
    }"#;
    let schedule: SceneSchedule = serde_json::from_str(json).unwrap();
    assert_eq!(schedule.slots["day"].from, fixed(6, 0));
    assert_eq!(schedule.slots["day"].to, fixed(23, 0));
}
