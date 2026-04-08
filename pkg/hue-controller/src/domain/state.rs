//! Per-zone runtime state held by the controller. Pure data — the state
//! transitions live in [`crate::controller`].
//!
//! There's one [`ZoneState`] per room. The whole state map is in-memory
//! only; on startup the controller asks the [`crate::mqtt`] bridge to
//! refresh `physically_on` from retained group topics (and `/get` queries
//! for any group that didn't have retained state). Everything else
//! (cycle index, last press timestamp, motion-sensor flags) starts at its
//! type default and gets populated by the first relevant event.

use std::collections::BTreeMap;
use std::time::Instant;

/// State for one room. Reset to [`ZoneState::default`] at startup; the
/// `physically_on` field is then refreshed from retained MQTT state
/// before the controller starts processing events.
#[derive(Debug, Clone, Default)]
pub struct ZoneState {
    /// Current physical state of the room's group, as last reported by
    /// `zigbee2mqtt/<group>`. Used as the toggle predicate by both the
    /// tap and switch handlers — supersedes the bento-era `lights_state`
    /// cache that we hand-maintained and which kept getting out of sync.
    pub physically_on: bool,

    /// Whether the room is currently in "motion" mode (i.e. lights were
    /// turned on by a motion sensor and not subsequently overridden by a
    /// user press). Only motion-on can transition to motion-off; once a
    /// user presses anything in the room, this clears.
    pub motion_owned: bool,

    /// Wall-switch / tap cycle index. Indexes into the active slot's
    /// `scene_ids` list at the moment of the press. Wraps modulo the
    /// list length on each cycle press.
    pub cycle_idx: usize,

    /// Monotonic timestamp of the most recent button press handled by
    /// this room. Used by the cycle predicate (`now - last_press <
    /// cycle_window`).
    pub last_press_at: Option<Instant>,

    /// Monotonic timestamp of the most recent OFF transition. Motion
    /// sensors compare against this to enforce their cooldown window.
    pub last_off_at: Option<Instant>,

    /// Per-motion-sensor "currently active" flags. Map key is the sensor
    /// friendly_name; value is true while that sensor's last reported
    /// `occupancy` is true. Used by the multi-sensor OR-gate so motion-off
    /// only fires when *every* sensor in the room reports inactive.
    pub motion_active_by_sensor: BTreeMap<String, bool>,
}

impl ZoneState {
    /// True if at least one motion sensor in the room is currently
    /// reporting occupancy.
    pub fn any_motion_active(&self) -> bool {
        self.motion_active_by_sensor.values().any(|&v| v)
    }

    /// True if every other sensor (i.e. all except `excluding`) is
    /// reporting inactive. Used by motion-off so a single sensor going
    /// idle doesn't turn the lights off while another is still seeing
    /// motion. Mirrors bento's `othersInactiveClause`.
    pub fn all_other_sensors_inactive(&self, excluding: &str) -> bool {
        self.motion_active_by_sensor
            .iter()
            .filter(|(name, _)| name.as_str() != excluding)
            .all(|(_, &active)| !active)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_off_and_empty() {
        let s = ZoneState::default();
        assert!(!s.physically_on);
        assert!(!s.motion_owned);
        assert_eq!(s.cycle_idx, 0);
        assert!(s.last_press_at.is_none());
        assert!(s.last_off_at.is_none());
        assert!(!s.any_motion_active());
    }

    #[test]
    fn other_sensors_inactive_excludes_self() {
        let mut s = ZoneState::default();
        s.motion_active_by_sensor.insert("a".into(), true);
        s.motion_active_by_sensor.insert("b".into(), false);
        // a is the one we're excluding (about to mark inactive); only b
        // matters → b is inactive → returns true.
        assert!(s.all_other_sensors_inactive("a"));
        // b is the one we're excluding; a is still active → returns false.
        assert!(!s.all_other_sensors_inactive("b"));
    }
}
