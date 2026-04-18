//! TRV (thermostatic radiator valve) TASS entity.

use std::time::{Duration, Instant};

use crate::tass::{TassActual, TassTarget, TargetPhase};

/// Running state reported by a TRV's internal PID controller.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum HeatingRunningState {
    #[default]
    Idle,
    Heat,
}

impl HeatingRunningState {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "idle" => Some(Self::Idle),
            "heat" => Some(Self::Heat),
            _ => None,
        }
    }

    pub fn is_heat(self) -> bool {
        self == Self::Heat
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum TrvTarget {
    /// Normal schedule-driven temperature.
    Setpoint(f64),
    /// Window open detected → min setpoint (5 C).
    Inhibited { until: Instant },
    /// Pressure group or min_cycle protection → max setpoint (30 C).
    ForcedOpen { reason: ForceOpenReason },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ForceOpenReason {
    PressureGroup,
    MinCycle,
}

#[derive(Debug, Clone)]
pub struct TrvActual {
    pub local_temperature: Option<f64>,
    pub pi_heating_demand: Option<u8>,
    pub running_state: HeatingRunningState,
    pub running_state_seen: bool,
    pub setpoint: Option<f64>,
    pub operating_mode: Option<String>,
    pub battery: Option<u8>,
}

impl Default for TrvActual {
    fn default() -> Self {
        Self {
            local_temperature: None,
            pi_heating_demand: None,
            running_state: HeatingRunningState::Idle,
            running_state_seen: false,
            setpoint: None,
            operating_mode: None,
            battery: None,
        }
    }
}

/// Open window detection algorithm state.
///
/// A detection cycle is active iff `baseline_established_at.is_some()`. The
/// cycle starts on the zone's relay-ON edge and ends on relay-OFF ([`reset`]).
#[derive(Debug, Clone, Default)]
pub struct OpenWindowState {
    /// Baseline temperature at relay-ON. `None` if the relay turned on while
    /// no fresh temperature reading was available — in that case the first
    /// post-ON sample backfills this field.
    pub temp_at_relay_on: Option<f64>,
    /// Highest temperature observed since detection started.
    pub temp_high_water: Option<f64>,
    /// True once detection has been performed in this relay-on cycle.
    pub checked: bool,
    /// When the detection cycle started (the relay-ON edge). The detection
    /// clock runs from this instant, independent of when the baseline sample
    /// was physically measured.
    pub baseline_established_at: Option<Instant>,
}

impl OpenWindowState {
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// Begin a detection cycle at `now` with the given baseline temperature
    /// (pass `None` if no fresh reading is available; the first arriving
    /// sample will backfill it).
    pub fn start_detection(&mut self, now: Instant, baseline_temp: Option<f64>) {
        self.temp_at_relay_on = baseline_temp;
        self.temp_high_water = baseline_temp;
        self.baseline_established_at = Some(now);
        self.checked = false;
    }
}

/// 30 minutes without any TRV state report = stale.
const STALE_THRESHOLD: Duration = Duration::from_secs(30 * 60);

/// A thermostatic radiator valve.
#[derive(Debug, Clone)]
pub struct TrvEntity {
    pub target: TassTarget<TrvTarget>,
    pub actual: TassActual<TrvActual>,
    pub open_window: OpenWindowState,
    /// When ANY state update was last received (device liveness).
    pub last_seen: Option<Instant>,
    /// When a temperature-bearing report was last received. Persists across
    /// relay on/off cycles so the next relay-ON edge can decide whether the
    /// last known temperature is fresh enough to use as a baseline.
    pub last_temp_at: Option<Instant>,
    /// Tick generation when setpoint was last changed (for dedup).
    pub setpoint_dirty_gen: u64,
    /// Remembers which force type was last applied (PressureGroup or MinCycle).
    /// Set when ForcedOpen is applied, cleared when the post-release setpoint
    /// is confirmed. Used by HA discovery to distinguish release states.
    pub last_force_reason: Option<ForceOpenReason>,
}

impl Default for TrvEntity {
    fn default() -> Self {
        Self {
            target: TassTarget::new(),
            actual: TassActual::new(),
            open_window: OpenWindowState::default(),
            last_seen: None,
            last_temp_at: None,
            setpoint_dirty_gen: 0,
            last_force_reason: None,
        }
    }
}

impl TrvEntity {
    /// True if this TRV hasn't reported ANY state for 30+ minutes.
    pub fn is_stale(&self, now: Instant) -> bool {
        self.last_seen
            .is_some_and(|seen| now.duration_since(seen) >= STALE_THRESHOLD)
    }

    /// True if we've received a temperature-bearing report recently enough
    /// that the last known temperature can be trusted as a detection baseline.
    pub fn has_fresh_temp(&self, now: Instant) -> bool {
        self.last_temp_at
            .is_some_and(|t| now.duration_since(t) < STALE_THRESHOLD)
    }

    /// True if this TRV is currently inhibited (open window protection).
    pub fn is_inhibited(&self, now: Instant) -> bool {
        self.target.value().is_some_and(|t| match t {
            TrvTarget::Inhibited { until } => now < *until,
            _ => false,
        })
    }

    /// True if this TRV is forced open (pressure group or min_cycle).
    pub fn is_forced_open(&self) -> bool {
        self.target
            .value()
            .is_some_and(|t| matches!(t, TrvTarget::ForcedOpen { .. }))
    }

    /// True if this TRV's target has been confirmed by the device.
    pub fn is_setpoint_confirmed(&self) -> bool {
        self.target.phase() == TargetPhase::Confirmed
    }

    /// True if the setpoint needs to be retried (commanded but not confirmed).
    pub fn needs_setpoint_retry(&self) -> bool {
        self.target.phase() == TargetPhase::Commanded
    }

    /// The setpoint value from the target (for normal setpoint targets).
    pub fn target_setpoint(&self) -> Option<f64> {
        self.target.value().and_then(|t| match t {
            TrvTarget::Setpoint(temp) => Some(*temp),
            _ => None,
        })
    }

    /// True if this TRV has organic heat demand (not from overrides).
    /// Excludes: inhibited, stale, forced-open, and release-pending TRVs.
    pub fn has_effective_demand(
        &self,
        now: Instant,
        min_demand: u8,
        min_demand_fallback: u8,
    ) -> bool {
        if self.is_inhibited(now) {
            return false;
        }
        if self.is_forced_open() {
            return false;
        }
        // Suppress demand during release (target just changed, phase=Commanded,
        // old demand readings from the forced setpoint are unreliable).
        if self.needs_setpoint_retry() {
            return false;
        }
        if self.is_stale(now) {
            return false;
        }
        self.has_raw_demand(min_demand, min_demand_fallback)
    }

    /// True if the TRV's PID controller is requesting heat, regardless
    /// of inhibition/force state.
    pub fn has_raw_demand(&self, min_demand: u8, min_demand_fallback: u8) -> bool {
        let Some(actual) = self.actual.value() else {
            return false;
        };
        let demand = actual.pi_heating_demand.unwrap_or(0);
        if actual.running_state_seen {
            actual.running_state.is_heat() && demand >= min_demand
        } else {
            demand >= min_demand_fallback
        }
    }
}

#[cfg(test)]
#[path = "trv_tests.rs"]
mod tests;
