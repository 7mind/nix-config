//! Time-of-day scene scheduling.
//!
//! Each room defines its scenes in terms of *slots* — disjoint time
//! ranges of the local day, each with its own ordered list of scenes for
//! the cycle button. The current production setup has just two slots
//! ("day" and "night") but the schema is open: any number of slots is
//! allowed as long as their time ranges cover the full 24h day exactly
//! once.
//!
//! Slot boundaries are [`TimeExpr`] values: either a fixed `"HH:MM"` or
//! a sun-relative `"sunrise/sunset ± HH:MM"`.
//!
//! Example (rendered by Nix from `defaultScheduledScenes`):
//!
//! ```jsonc
//! {
//!   "slots": {
//!     "day":   { "from": "06:00",  "to": "23:00", "scene_ids": [1, 2, 3] },
//!     "night": { "from": "23:00",  "to": "06:00", "scene_ids": [3, 2, 1] }
//!   },
//!   "scenes": [
//!     { "id": 1, "name": "bright",  "brightness": 254, "color_temp": 250 },
//!     { "id": 2, "name": "relaxed", "brightness": 180, "color_temp": 350 },
//!     { "id": 3, "name": "dim",     "brightness":  60, "color_temp": 500 }
//!   ]
//! }
//! ```
//!
//! The `scenes` list is consumed by provisioning (one `scene_add` per
//! entry). The `slots` map drives the runtime cycle: at button press time,
//! the controller picks the slot whose time range contains "now", then
//! cycles through that slot's `scene_ids` in order.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use super::time_expr::TimeExpr;
use crate::sun::SunTimes;

/// Slot identifier — typically `"day"` or `"night"`. Free-form string so
/// the user can introduce more granular slots (e.g. `"morning"`,
/// `"evening"`) without code changes.
pub type SlotName = String;

/// Per-room scene configuration. Provisioning consumes `scenes`; the
/// runtime consumes `slots` plus the `id` lookup back into `scenes` for
/// each cycled scene id.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SceneSchedule {
    /// All scenes that should exist on this room's z2m group. The cycle
    /// references each by `id`. The runtime never reads brightness/color
    /// values from here — those are baked into the scenes when the
    /// provisioner calls `scene_add`.
    pub scenes: Vec<Scene>,

    /// Time-of-day → cycle order. Each slot's `scene_ids` is the ordered
    /// list the cycle button walks through.
    pub slots: BTreeMap<SlotName, Slot>,
}

/// One scene definition. Mirrors hue-setup's `SceneSpec`.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Scene {
    /// Scene id local to its z2m group, 1..=255.
    pub id: u8,

    pub name: String,

    /// `"ON"` or `"OFF"` — passed straight through to z2m's `scene_add`.
    /// Defaults to `"ON"` because that's the only useful value for our
    /// usage.
    #[serde(default = "default_scene_state")]
    pub state: String,

    pub brightness: Option<u8>,

    pub color_temp: Option<u16>,

    /// Scene transition duration in seconds. The provisioner adds an
    /// epsilon to force `Number.isInteger` to return false on the JS
    /// side, which steers z2m's converter into the `enhancedAdd` path
    /// that Hue bulbs actually honour. See `provision::scenes`.
    #[serde(default)]
    pub transition: f64,
}

fn default_scene_state() -> String {
    "ON".to_string()
}

/// One time-of-day slot. `from` is inclusive, `to` is exclusive.
/// Wrapping midnight is supported: `from: "23:00", to: "06:00"` means
/// 23:00–24:00 ∪ 00:00–06:00.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Slot {
    pub from: TimeExpr,
    pub to: TimeExpr,
    /// Ordered cycle: pressing the cycle button advances through this list.
    pub scene_ids: Vec<u8>,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum SceneScheduleError {
    #[error("slot {name:?} `from` time is out of range: {expr}")]
    FromOutOfRange { name: SlotName, expr: String },

    #[error("slot {name:?} `to` time is out of range: {expr}")]
    ToOutOfRange { name: SlotName, expr: String },

    #[error("slot {name:?} references scene id {id} which is not in the room's `scenes` list")]
    UnknownSceneId { name: SlotName, id: u8 },

    #[error("the {count} slot(s) defined do not exactly cover 24 hours; coverage map has {uncovered} uncovered minutes")]
    IncompleteCoverage { count: usize, uncovered: usize },

    #[error("minute {minute} is covered by multiple slots: {slots:?}")]
    OverlappingSlots { minute: u16, slots: Vec<SlotName> },
}

impl Slot {
    /// True iff local time `(h, m)` falls in this slot. Handles midnight
    /// wrap. `sun` is required when the slot uses sun-relative boundaries.
    pub fn contains_time(&self, h: u8, m: u8, sun: Option<&SunTimes>) -> bool {
        let start = self.from.resolve(sun);
        let end = self.to.resolve(sun);
        let now = h as u16 * 60 + m as u16;
        if start <= end {
            now >= start && now < end
        } else {
            // Wraps midnight.
            now >= start || now < end
        }
    }

    /// True if either boundary uses a sun-relative expression.
    pub fn uses_sun(&self) -> bool {
        self.from.uses_sun() || self.to.uses_sun()
    }
}

impl SceneSchedule {
    /// True if any slot boundary references sunrise/sunset.
    pub fn uses_sun_expressions(&self) -> bool {
        self.slots.values().any(|s| s.uses_sun())
    }

    /// Validate the schedule:
    ///   * every `scene_ids` entry refers to a scene in `scenes`
    ///   * if all boundaries are fixed, every minute 0..1440 is covered
    ///     by exactly one slot
    ///
    /// When sun-relative expressions are present, coverage validation is
    /// skipped (boundaries change daily).
    pub fn validate(&self) -> Result<(), SceneScheduleError> {
        let known_scene_ids: std::collections::BTreeSet<u8> =
            self.scenes.iter().map(|s| s.id).collect();

        // Cross-reference: every cycle id must exist as a scene definition.
        for (slot_name, slot) in &self.slots {
            // Validate fixed boundaries are in range.
            if let TimeExpr::Fixed { minute_of_day } = &slot.from {
                if *minute_of_day > 1440 {
                    return Err(SceneScheduleError::FromOutOfRange {
                        name: slot_name.clone(),
                        expr: slot.from.to_string(),
                    });
                }
            }
            if let TimeExpr::Fixed { minute_of_day } = &slot.to {
                if *minute_of_day > 1440 {
                    return Err(SceneScheduleError::ToOutOfRange {
                        name: slot_name.clone(),
                        expr: slot.to.to_string(),
                    });
                }
            }
            for &id in &slot.scene_ids {
                if !known_scene_ids.contains(&id) {
                    return Err(SceneScheduleError::UnknownSceneId {
                        name: slot_name.clone(),
                        id,
                    });
                }
            }
        }

        // Coverage validation only when all boundaries are fixed.
        if !self.uses_sun_expressions() {
            self.validate_coverage(None)?;
        }

        Ok(())
    }

    /// Check that every minute 0..1440 is covered by exactly one slot.
    /// When `sun` is `Some`, resolves sun-relative boundaries; when
    /// `None`, only works if all boundaries are fixed.
    fn validate_coverage(&self, sun: Option<&SunTimes>) -> Result<(), SceneScheduleError> {
        // Check all 1440 minutes for minute-precise validation.
        let mut owners: Vec<Vec<SlotName>> = vec![vec![]; 1440];
        for (slot_name, slot) in &self.slots {
            for m in 0..1440u16 {
                let h = (m / 60) as u8;
                let min = (m % 60) as u8;
                if slot.contains_time(h, min, sun) {
                    owners[m as usize].push(slot_name.clone());
                }
            }
        }
        for (m, slot_owners) in owners.iter().enumerate() {
            if slot_owners.len() > 1 {
                return Err(SceneScheduleError::OverlappingSlots {
                    minute: m as u16,
                    slots: slot_owners.clone(),
                });
            }
        }
        let uncovered = owners.iter().filter(|v| v.is_empty()).count();
        if uncovered > 0 {
            return Err(SceneScheduleError::IncompleteCoverage {
                count: self.slots.len(),
                uncovered,
            });
        }
        Ok(())
    }

    /// Pick the slot whose time range contains `(hour, minute)`. Assumes
    /// `validate` has already been called. Returns `None` only if no slot
    /// covers this time (invalid schedule).
    pub fn slot_for_time(
        &self,
        hour: u8,
        minute: u8,
        sun: Option<&SunTimes>,
    ) -> Option<(&SlotName, &Slot)> {
        self.slots
            .iter()
            .find(|(_, slot)| slot.contains_time(hour, minute, sun))
    }
}

#[cfg(test)]
mod tests {
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
}
