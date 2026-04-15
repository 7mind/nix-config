//! Heating zone TASS entity. One per heating zone (relay + TRVs).

use std::time::{Duration, Instant};

use crate::tass::{TassActual, TassTarget};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HeatingZoneTarget {
    Heating,
    Off,
}

#[derive(Debug, Clone, PartialEq)]
pub struct HeatingZoneActual {
    pub relay_on: bool,
    pub temperature: Option<f64>,
}

/// Wall thermostat staleness threshold: 10 minutes.
const WT_STALE_THRESHOLD: Duration = Duration::from_secs(10 * 60);

/// A heating zone controlling a relay (wall thermostat).
#[derive(Debug, Clone)]
pub struct HeatingZoneEntity {
    pub target: TassTarget<HeatingZoneTarget>,
    pub actual: TassActual<HeatingZoneActual>,
    /// When the relay was confirmed on. For min_cycle enforcement.
    pub relay_on_since: Option<Instant>,
    /// Last reported operating_mode from wall thermostat.
    pub wt_operating_mode: Option<String>,
    /// When the wall thermostat last reported any state.
    pub wt_last_seen: Option<Instant>,
    /// True once the wall thermostat has reported at least once.
    pub relay_state_known: bool,
    /// Tick generation for dedup (prevents double-publish in one pass).
    pub desired_relay_gen: u64,
}

impl Default for HeatingZoneEntity {
    fn default() -> Self {
        Self {
            target: TassTarget::new(),
            actual: TassActual::new(),
            relay_on_since: None,
            wt_operating_mode: None,
            wt_last_seen: None,
            relay_state_known: false,
            desired_relay_gen: 0,
        }
    }
}

impl HeatingZoneEntity {
    /// True if the relay is currently on (from actual state).
    pub fn is_relay_on(&self) -> bool {
        self.actual.value().is_some_and(|a| a.relay_on)
    }

    /// True if the wall thermostat hasn't reported for 10+ minutes.
    pub fn is_wt_stale(&self, now: Instant) -> bool {
        self.wt_last_seen
            .is_some_and(|seen| now.duration_since(seen) >= WT_STALE_THRESHOLD)
    }
}
