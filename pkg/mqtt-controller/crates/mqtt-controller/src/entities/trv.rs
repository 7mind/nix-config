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
#[derive(Debug, Clone, Default)]
pub struct OpenWindowState {
    /// Temperature when relay turned on (baseline for detection).
    pub temp_at_relay_on: Option<f64>,
    /// Highest temperature observed since relay turned on.
    pub temp_high_water: Option<f64>,
    /// True once detection has been performed in this relay-on cycle.
    pub checked: bool,
    /// True when relay turned on but no fresh temp was available for baseline.
    pub awaiting_baseline: bool,
    /// When the baseline was established (for detection window measurement).
    pub baseline_established_at: Option<Instant>,
    /// When the last temperature sample was received.
    pub temp_last_updated: Option<Instant>,
}

impl OpenWindowState {
    pub fn reset(&mut self) {
        *self = Self::default();
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
mod tests {
    use super::*;
    use crate::tass::Owner;

    #[test]
    fn running_state_parse() {
        assert_eq!(HeatingRunningState::parse("idle"), Some(HeatingRunningState::Idle));
        assert_eq!(HeatingRunningState::parse("heat"), Some(HeatingRunningState::Heat));
        assert_eq!(HeatingRunningState::parse("cool"), None);
    }

    #[test]
    fn trv_inhibition() {
        let now = Instant::now();
        let mut trv = TrvEntity::default();

        trv.target.set_and_command(
            TrvTarget::Inhibited {
                until: now + Duration::from_secs(60),
            },
            Owner::Rule,
            now,
        );
        assert!(trv.is_inhibited(now));
        assert!(!trv.is_inhibited(now + Duration::from_secs(61)));
    }

    #[test]
    fn trv_forced_open() {
        let now = Instant::now();
        let mut trv = TrvEntity::default();

        trv.target.set_and_command(
            TrvTarget::ForcedOpen {
                reason: ForceOpenReason::PressureGroup,
            },
            Owner::Rule,
            now,
        );
        assert!(trv.is_forced_open());
        assert!(!trv.is_inhibited(now));
    }

    #[test]
    fn trv_demand_suppressed_during_release() {
        let now = Instant::now();
        let mut trv = TrvEntity::default();

        // Simulate: normal setpoint, has demand
        let mut actual = TrvActual::default();
        actual.running_state = HeatingRunningState::Heat;
        actual.running_state_seen = true;
        actual.pi_heating_demand = Some(50);
        trv.actual.update(actual, now);

        // Confirmed setpoint → demand counts
        trv.target
            .set_and_command(TrvTarget::Setpoint(21.0), Owner::Schedule, now);
        trv.target.confirm(now);
        assert!(trv.has_effective_demand(now, 5, 80));

        // New setpoint commanded (release from force) → demand suppressed
        trv.target
            .set_and_command(TrvTarget::Setpoint(18.0), Owner::Schedule, now);
        assert!(!trv.has_effective_demand(now, 5, 80));
        assert!(trv.has_raw_demand(5, 80)); // raw demand still present
    }
}
