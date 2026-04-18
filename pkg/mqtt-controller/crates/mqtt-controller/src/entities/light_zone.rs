//! Light zone TASS entity. One per room/group.

use std::time::Instant;

use crate::tass::{Owner, TassActual, TassTarget};

#[derive(Debug, Clone, PartialEq)]
pub enum LightZoneTarget {
    Off,
    On { scene_id: u8, cycle_idx: usize },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LightZoneActual {
    On,
    Off,
}

/// A controllable light zone (room group).
#[derive(Debug, Clone)]
pub struct LightZoneEntity {
    pub target: TassTarget<LightZoneTarget>,
    pub actual: TassActual<LightZoneActual>,
    /// Timestamp of most recent button press (for cycle window).
    pub last_press_at: Option<Instant>,
    /// Timestamp of most recent OFF transition (for motion cooldown).
    pub last_off_at: Option<Instant>,
}

impl Default for LightZoneEntity {
    fn default() -> Self {
        Self {
            target: TassTarget::new(),
            actual: TassActual::new(),
            last_press_at: None,
            last_off_at: None,
        }
    }
}

impl LightZoneEntity {
    /// True if the zone is considered "on" for toggle/cycle decisions.
    /// Optimistic: true if target says On (commanded but maybe not
    /// confirmed yet) OR actual reports On (externally turned on).
    pub fn is_on(&self) -> bool {
        self.target_is_on() || self.actual_is_on()
    }

    /// True if the target value is On.
    pub fn target_is_on(&self) -> bool {
        self.target
            .value()
            .is_some_and(|t| matches!(t, LightZoneTarget::On { .. }))
    }

    /// True if the last actual reading is On.
    pub fn actual_is_on(&self) -> bool {
        self.actual.value() == Some(&LightZoneActual::On)
    }

    /// Current scene cycle index from the target, or 0 if unset/off.
    pub fn cycle_idx(&self) -> usize {
        self.target
            .value()
            .and_then(|t| match t {
                LightZoneTarget::On { cycle_idx, .. } => Some(*cycle_idx),
                _ => None,
            })
            .unwrap_or(0)
    }

    /// True if motion automation owns this zone.
    pub fn is_motion_owned(&self) -> bool {
        self.target.owner() == Some(Owner::Motion)
    }
}

#[cfg(test)]
#[path = "light_zone_tests.rs"]
mod tests;
