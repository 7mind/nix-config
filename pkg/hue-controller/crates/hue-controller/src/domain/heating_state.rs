//! Runtime state for the heating subsystem. Pure data — the state
//! transitions live in [`crate::controller::heating`].

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

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

/// Global heating runtime state held by the controller.
#[derive(Debug, Clone)]
pub struct HeatingRuntimeState {
    /// When the first relay turned on (pump started). `None` if all
    /// relays are off.
    pub pump_on_since: Option<Instant>,

    /// When the last relay turned off (pump stopped), as confirmed by
    /// MQTT echo. `None` if any relay is currently on, or if the pump
    /// has never run.
    pub pump_off_since: Option<Instant>,

    // Per-zone pending ON/OFF tracking in HeatingZoneRuntimeState.

    /// Per-zone state, keyed by zone name.
    pub zones: BTreeMap<String, HeatingZoneRuntimeState>,
}

impl HeatingRuntimeState {
    pub fn new() -> Self {
        Self {
            pump_on_since: None,
            pump_off_since: None,
            zones: BTreeMap::new(),
        }
    }

    /// The most conservative pump-off timestamp: the most recent of
    /// the confirmed echo and any per-zone pending OFF. Per-zone
    /// tracking prevents one zone's echo from clearing another's
    /// pending stop.
    pub fn effective_pump_off_since(&self) -> Option<Instant> {
        let latest_pending = self.zones.values()
            .filter_map(|zs| zs.pending_off_at)
            .max();
        match (self.pump_off_since, latest_pending) {
            (Some(a), Some(b)) => Some(a.max(b)),
            (a, b) => a.or(b),
        }
    }

    /// The earliest pump-on timestamp (confirmed or any per-zone pending
    /// that is still desired ON). Zones being cancelled (desired=false
    /// with pending_on_at) are excluded so their phantom timestamps
    /// don't artificially extend min_cycle for other zones.
    pub fn effective_pump_on_since(&self) -> Option<Instant> {
        let earliest_pending = self.zones.values()
            .filter(|zs| zs.desired_relay != Some(false))
            .filter_map(|zs| zs.pending_on_at)
            .min();
        match (self.pump_on_since, earliest_pending) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }
    }

    /// True if any zone has a pending ON (requested but not echoed).
    pub fn has_any_pending_on(&self) -> bool {
        self.zones.values().any(|zs| zs.pending_on_at.is_some())
    }

    /// True if any zone's relay is currently on (pump is running).
    pub fn is_pump_running(&self) -> bool {
        self.zones.values().any(|z| z.relay_on)
    }

    /// Count of zones with relay currently on.
    pub fn active_relay_count(&self) -> usize {
        self.zones.values().filter(|z| z.relay_on).count()
    }
}

/// Per-zone heating state.
#[derive(Debug, Clone)]
pub struct HeatingZoneRuntimeState {
    /// Confirmed relay state from the wall thermostat's MQTT echo.
    /// Only updated by `handle_wall_thermostat_state`.
    pub relay_on: bool,

    /// Last reported operating_mode from the wall thermostat.
    /// Must be `"manual"` for safe relay control.
    pub wt_operating_mode: Option<String>,

    /// True once the wall thermostat has reported at least one state
    /// update. Zones with unconfirmed relay state are excluded from
    /// relay control decisions (safe default after startup).
    pub relay_state_known: bool,

    /// When this zone's relay was last confirmed on (from MQTT echo).
    pub relay_on_since: Option<Instant>,

    /// What the controller wants the relay to be. Set by `evaluate_relays`.
    /// When this differs from `relay_on`, the reconciliation step retries
    /// the command until the wall thermostat echoes back.
    pub desired_relay: Option<bool>,

    /// Tick generation when `desired_relay` was last changed.
    /// Reconciliation skips entries changed in the current tick.
    pub desired_relay_gen: u64,

    /// When the controller requested relay ON for this zone and the
    /// echo hasn't arrived yet. Per-zone so that another zone's
    /// repeated OFF echo can't clear it. Used for min_cycle enforcement
    /// on stale-ON cancellation.
    pub pending_on_at: Option<Instant>,

    /// When the controller requested relay OFF for this zone and the
    /// echo hasn't confirmed it yet. Per-zone so that one zone's echo
    /// can't erase another's pending stop for min_pause enforcement.
    pub pending_off_at: Option<Instant>,

    /// Per-TRV state, keyed by TRV device friendly_name.
    pub trvs: BTreeMap<String, TrvRuntimeState>,
}

impl HeatingZoneRuntimeState {
    pub fn new() -> Self {
        Self {
            relay_on: false,
            wt_operating_mode: None,
            relay_state_known: false,
            relay_on_since: None,
            desired_relay: None,
            desired_relay_gen: 0,
            pending_on_at: None,
            pending_off_at: None,
            trvs: BTreeMap::new(),
        }
    }

    /// True if any non-inhibited TRV in this zone has heat demand.
    pub fn has_effective_demand(&self, now: Instant) -> bool {
        self.trvs.values().any(|t| t.has_effective_demand(now))
    }
}

/// Per-TRV heating state.
#[derive(Debug, Clone)]
pub struct TrvRuntimeState {
    /// When the last state update was received from this TRV.
    /// Used for staleness detection: if no update arrives for a
    /// configurable period, demand is suppressed to prevent a dead
    /// TRV from keeping the zone heating indefinitely.
    pub last_seen: Option<Instant>,

    /// Last reported operating_mode from the TRV.
    /// Must be `"manual"` for safe controller operation.
    pub operating_mode: Option<String>,

    /// Last reported battery percentage.
    pub battery: Option<u8>,

    /// Last reported local temperature.
    pub local_temperature: Option<f64>,

    /// Last reported pi_heating_demand (0-100).
    pub pi_heating_demand: Option<u8>,

    /// Last reported running state from TRV's PID controller.
    pub running_state: HeatingRunningState,

    /// True once we've received at least one `running_state` report
    /// from this TRV. When true, demand evaluation uses `running_state`
    /// exclusively (the canonical signal). When false, falls back to
    /// `pi_heating_demand` as a best-effort substitute.
    pub running_state_seen: bool,

    /// Last setpoint WE sent to this TRV (for dedup and restore).
    pub last_sent_setpoint: Option<f64>,

    /// True once the device has echoed back a setpoint matching
    /// `last_sent_setpoint`. Until confirmed, the schedule evaluator
    /// does not deduplicate and the reconciler retries the write.
    pub setpoint_confirmed: bool,

    /// Tick generation when `setpoint_confirmed` was last set to false.
    /// Reconciliation skips entries dirtied in the current tick to
    /// avoid publishing the same command twice in one pass.
    pub setpoint_dirty_gen: u64,

    /// Last setpoint the device reported back.
    pub reported_setpoint: Option<f64>,

    /// True if this TRV's setpoint has been overridden to 30°C for
    /// pressure group enforcement.
    pub pressure_forced: bool,

    /// True after a pressure-group release until the normal setpoint
    /// is confirmed. Suppresses demand evaluation to prevent stale
    /// demand from the 30°C override from keeping the zone active.
    pub pressure_release_pending: bool,

    /// If set, this TRV is inhibited (open window detected) until this
    /// instant. Inhibited TRVs are excluded from demand evaluation and
    /// have their setpoint lowered to minimum.
    pub inhibited_until: Option<Instant>,

    /// Temperature recorded when the zone relay turned on. Used for
    /// open window detection (compare against high-water mark).
    pub temp_at_relay_on: Option<f64>,

    /// Highest temperature observed since relay turned on. If this ever
    /// exceeds `temp_at_relay_on`, the open-window check considers the
    /// room to have warmed and skips inhibition. This prevents false
    /// triggers from non-monotonic temperature curves.
    pub temp_high_water: Option<f64>,

    /// True once the open-window check has been performed for this TRV
    /// in the current relay-on cycle. Prevents repeated checks from
    /// false-triggering on normal temperature drift during long heating
    /// runs. Reset when the relay turns off or on again.
    pub open_window_checked: bool,
}

impl TrvRuntimeState {
    pub fn new() -> Self {
        Self {
            last_seen: None,
            operating_mode: None,
            battery: None,
            local_temperature: None,
            pi_heating_demand: None,
            running_state: HeatingRunningState::Idle,
            running_state_seen: false,
            last_sent_setpoint: None,
            setpoint_confirmed: true, // no pending write
            setpoint_dirty_gen: 0,
            reported_setpoint: None,
            pressure_forced: false,
            pressure_release_pending: false,
            inhibited_until: None,
            temp_at_relay_on: None,
            temp_high_water: None,
            open_window_checked: false,
        }
    }

    /// True if the setpoint needs to be retried: we sent a value that
    /// the device hasn't confirmed yet.
    pub fn needs_setpoint_retry(&self) -> bool {
        self.last_sent_setpoint.is_some() && !self.setpoint_confirmed
    }

    /// True if this TRV is currently inhibited (open window protection).
    pub fn is_inhibited(&self, now: Instant) -> bool {
        self.inhibited_until.is_some_and(|until| now < until)
    }

    /// 30 minutes without any TRV state report = stale.
    const STALE_THRESHOLD_SECS: u64 = 30 * 60;

    /// True if this TRV hasn't reported any state for a long time.
    /// A stale TRV's demand is suppressed to prevent indefinite heating
    /// from a dead device.
    pub fn is_stale(&self, now: Instant) -> bool {
        self.last_seen.is_some_and(|seen| {
            now.duration_since(seen) >= Duration::from_secs(Self::STALE_THRESHOLD_SECS)
        })
    }

    /// True if this TRV has ORGANIC heat demand (not from a pressure
    /// group override). Excludes: inhibited, stale, pressure-forced,
    /// and pressure-release-pending TRVs. This is what drives relay
    /// control — only real heating demand should keep relays on.
    pub fn has_effective_demand(&self, now: Instant) -> bool {
        if self.is_inhibited(now) {
            return false;
        }
        if self.pressure_forced || self.pressure_release_pending {
            return false;
        }
        if self.is_stale(now) {
            return false;
        }
        self.has_raw_demand()
    }

    /// True if the TRV's PID controller is requesting heat, regardless
    /// of inhibition state. Uses a single canonical signal to avoid
    /// demand latching from stale partial updates:
    ///   - If `running_state` has ever been reported, use it exclusively.
    ///   - Otherwise, fall back to `pi_heating_demand > 0`.
    pub fn has_raw_demand(&self) -> bool {
        if self.running_state_seen {
            self.running_state.is_heat()
        } else {
            self.pi_heating_demand.is_some_and(|d| d > 0)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn running_state_parse() {
        assert_eq!(HeatingRunningState::parse("idle"), Some(HeatingRunningState::Idle));
        assert_eq!(HeatingRunningState::parse("heat"), Some(HeatingRunningState::Heat));
        assert_eq!(HeatingRunningState::parse("cool"), None);
    }

    #[test]
    fn trv_demand_from_running_state() {
        let mut t = TrvRuntimeState::new();
        assert!(!t.has_raw_demand());
        t.running_state = HeatingRunningState::Heat;
        t.running_state_seen = true;
        assert!(t.has_raw_demand());
    }

    #[test]
    fn trv_demand_from_pi_heating_demand() {
        let mut t = TrvRuntimeState::new();
        t.pi_heating_demand = Some(50);
        assert!(t.has_raw_demand());
        t.pi_heating_demand = Some(0);
        assert!(!t.has_raw_demand());
    }

    #[test]
    fn inhibition_blocks_effective_demand() {
        let now = Instant::now();
        let mut t = TrvRuntimeState::new();
        t.running_state = HeatingRunningState::Heat;
        t.running_state_seen = true;
        assert!(t.has_effective_demand(now));

        t.inhibited_until = Some(now + Duration::from_secs(60));
        assert!(!t.has_effective_demand(now));
        assert!(t.has_raw_demand()); // raw demand still present

        // After inhibition expires:
        assert!(t.has_effective_demand(now + Duration::from_secs(61)));
    }

    #[test]
    fn zone_effective_demand() {
        let now = Instant::now();
        let mut zone = HeatingZoneRuntimeState::new();
        assert!(!zone.has_effective_demand(now));

        let mut t1 = TrvRuntimeState::new();
        t1.running_state = HeatingRunningState::Heat;
        t1.running_state_seen = true;
        zone.trvs.insert("t1".into(), t1);
        assert!(zone.has_effective_demand(now));

        // Inhibit the only demanding TRV:
        zone.trvs.get_mut("t1").unwrap().inhibited_until =
            Some(now + Duration::from_secs(60));
        assert!(!zone.has_effective_demand(now));
    }

    #[test]
    fn pump_running_tracking() {
        let mut state = HeatingRuntimeState::new();
        assert!(!state.is_pump_running());
        assert_eq!(state.active_relay_count(), 0);

        state.zones.insert("z1".into(), HeatingZoneRuntimeState::new());
        state.zones.get_mut("z1").unwrap().relay_on = true;
        assert!(state.is_pump_running());
        assert_eq!(state.active_relay_count(), 1);
    }
}
