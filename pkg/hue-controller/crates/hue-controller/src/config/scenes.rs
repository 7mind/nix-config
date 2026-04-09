//! Time-of-day scene scheduling.
//!
//! Each room defines its scenes in terms of *slots* — disjoint hour
//! ranges of the local day, each with its own ordered list of scenes for
//! the cycle button. The current bento implementation has just two slots
//! ("day" and "night") in production but the schema is open: any number
//! of slots is allowed as long as their hour ranges cover the full 24h
//! day exactly once.
//!
//! Example (rendered by Nix from `defaultScheduledScenes`):
//!
//! ```jsonc
//! {
//!   "slots": {
//!     "day":   { "start_hour": 6,  "end_hour_exclusive": 23, "scene_ids": [1, 2, 3] },
//!     "night": { "start_hour": 23, "end_hour_exclusive": 6,  "scene_ids": [3, 2, 1] }
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
//! the controller picks the slot whose hour range contains "now", then
//! cycles through that slot's `scene_ids` in order.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use thiserror::Error;

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

/// Hour range for one slot. `start_hour` is inclusive, `end_hour_exclusive`
/// is exclusive. The night slot wraps midnight: `start=23, end=6` means
/// "23:00 .. 24:00 ∪ 00:00 .. 06:00".
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Slot {
    pub start_hour: u8,
    pub end_hour_exclusive: u8,
    /// Ordered cycle: pressing the cycle button advances through this list.
    pub scene_ids: Vec<u8>,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum SceneScheduleError {
    #[error("hour {hour} is out of range — must be 0..=23")]
    HourOutOfRange { hour: u8 },

    #[error("slot {name:?} references scene id {id} which is not in the room's `scenes` list")]
    UnknownSceneId { name: SlotName, id: u8 },

    #[error("the {count} slot(s) defined do not exactly cover 24 hours; coverage map is {coverage:?}")]
    IncompleteCoverage { count: usize, coverage: Vec<u8> },

    #[error("hour {hour} is covered by multiple slots: {slots:?}")]
    OverlappingSlots { hour: u8, slots: Vec<SlotName> },
}

impl Slot {
    /// True iff the local hour `h` falls in this slot. Handles wrap.
    pub fn contains_hour(&self, h: u8) -> bool {
        if self.start_hour <= self.end_hour_exclusive {
            // Normal range, e.g. day = [6, 23): 6,7,...,22.
            h >= self.start_hour && h < self.end_hour_exclusive
        } else {
            // Wrap-around range, e.g. night = [23, 6): 23, then 0..5.
            h >= self.start_hour || h < self.end_hour_exclusive
        }
    }
}

impl SceneSchedule {
    /// Validate the schedule:
    ///   * every hour 0..24 is covered by exactly one slot
    ///   * every `scene_ids` entry refers to a scene in `scenes`
    pub fn validate(&self) -> Result<(), SceneScheduleError> {
        let known_scene_ids: std::collections::BTreeSet<u8> =
            self.scenes.iter().map(|s| s.id).collect();

        // Cross-reference: every cycle id must exist as a scene definition.
        for (slot_name, slot) in &self.slots {
            if slot.start_hour >= 24 {
                return Err(SceneScheduleError::HourOutOfRange {
                    hour: slot.start_hour,
                });
            }
            if slot.end_hour_exclusive > 24 {
                return Err(SceneScheduleError::HourOutOfRange {
                    hour: slot.end_hour_exclusive,
                });
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

        // Coverage: every hour 0..24 must be claimed by exactly one slot.
        // Build a 24-element vector recording which slots claim each hour.
        let mut owners: Vec<Vec<SlotName>> = vec![vec![]; 24];
        for (slot_name, slot) in &self.slots {
            for h in 0..24u8 {
                if slot.contains_hour(h) {
                    owners[h as usize].push(slot_name.clone());
                }
            }
        }
        for (h, slot_owners) in owners.iter().enumerate() {
            if slot_owners.len() > 1 {
                return Err(SceneScheduleError::OverlappingSlots {
                    hour: h as u8,
                    slots: slot_owners.clone(),
                });
            }
        }
        let coverage_count: Vec<u8> = owners.iter().map(|v| v.len() as u8).collect();
        if coverage_count.iter().any(|&c| c == 0) {
            return Err(SceneScheduleError::IncompleteCoverage {
                count: self.slots.len(),
                coverage: coverage_count,
            });
        }

        Ok(())
    }

    /// Pick the slot whose hour range contains `hour`. Assumes `validate`
    /// has already been called — returns `None` only if the schedule is
    /// invalid (no slot covers this hour).
    pub fn slot_for_hour(&self, hour: u8) -> Option<(&SlotName, &Slot)> {
        self.slots.iter().find(|(_, slot)| slot.contains_hour(hour))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

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
                        start_hour: 6,
                        end_hour_exclusive: 23,
                        scene_ids: vec![1, 2, 3],
                    },
                ),
                (
                    "night".into(),
                    Slot {
                        start_hour: 23,
                        end_hour_exclusive: 6,
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

        let (name, slot) = s.slot_for_hour(12).unwrap();
        assert_eq!(name, "day");
        assert_eq!(slot.scene_ids, vec![1, 2, 3]);

        let (name, _) = s.slot_for_hour(23).unwrap();
        assert_eq!(name, "night");

        let (name, _) = s.slot_for_hour(2).unwrap();
        assert_eq!(name, "night");
    }

    #[test]
    fn slot_contains_hour_normal_range() {
        let s = Slot {
            start_hour: 6,
            end_hour_exclusive: 23,
            scene_ids: vec![],
        };
        assert!(!s.contains_hour(5));
        assert!(s.contains_hour(6));
        assert!(s.contains_hour(22));
        assert!(!s.contains_hour(23));
    }

    #[test]
    fn slot_contains_hour_wrap_range() {
        let s = Slot {
            start_hour: 23,
            end_hour_exclusive: 6,
            scene_ids: vec![],
        };
        assert!(s.contains_hour(23));
        assert!(s.contains_hour(0));
        assert!(s.contains_hour(5));
        assert!(!s.contains_hour(6));
        assert!(!s.contains_hour(22));
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
        // Make night start at 22 instead of 23 → overlaps with day (which
        // ends-exclusive at 23, so the day slot still covers hour 22).
        s.slots.get_mut("night").unwrap().start_hour = 22;
        let err = s.validate().unwrap_err();
        assert!(matches!(
            err,
            SceneScheduleError::OverlappingSlots { hour: 22, .. }
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
                    start_hour: 6,
                    end_hour_exclusive: 22,
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
}
