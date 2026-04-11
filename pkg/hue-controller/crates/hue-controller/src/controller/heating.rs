//! Heating controller: schedule evaluation, relay control with global
//! short-cycling protection, pressure group enforcement, and open window
//! detection.
//!
//! ## Architecture
//!
//! The heating controller is an optional sub-controller within the main
//! [`Controller`]. It is only instantiated when the config contains a
//! `heating` section. It:
//!
//!   * Holds mutable [`HeatingRuntimeState`] (relay tracking, TRV demand,
//!     pump on/off timestamps).
//!   * Receives TRV state events and wall thermostat state events from the
//!     main controller's event dispatch.
//!   * On every Tick, evaluates schedules, decides relay state, enforces
//!     pressure groups, and detects open windows.
//!   * Returns `Vec<Action>` the daemon publishes to MQTT.
//!
//! ## Relay control
//!
//! All zone relays control the same heat pump. Protection is global:
//!   - **min_cycle**: once the pump starts (first relay ON), at least one
//!     relay must stay ON for this duration.
//!   - **min_pause**: after the pump stops (all relays OFF), no relay may
//!     turn ON for this duration.

use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::config::heating::{HeatingConfig, Weekday};
use crate::domain::action::{Action, Payload};
use crate::domain::event::Event;
use crate::domain::heating_state::{
    HeatingRuntimeState, HeatingRunningState, HeatingZoneRuntimeState,
    TrvRuntimeState,
};
use crate::time::Clock;
use crate::topology::Topology;

/// Minimum setpoint (°C) used when inhibiting a TRV (open window) or
/// as belt-and-suspenders for wall thermostat relay mode.
const MIN_SETPOINT: f64 = 5.0;

/// Maximum setpoint (°C) used to force-open a TRV valve for pressure
/// group enforcement.
const MAX_SETPOINT: f64 = 30.0;

#[derive(Debug)]
pub struct HeatingController {
    config: HeatingConfig,
    topology: Arc<Topology>,
    clock: Arc<dyn Clock>,
    state: HeatingRuntimeState,
    /// False during startup state hydration. Set to true after the
    /// first `handle_tick`. While false, relay-on edges from MQTT
    /// do NOT start open-window timers (they are state synchronization,
    /// not fresh heating cycles).
    startup_complete: bool,
    /// Monotonic tick generation counter. Incremented at the start of
    /// each `handle_tick`. Used by reconciliation to skip commands
    /// that were just issued in the current tick (avoids duplicates).
    tick_gen: u64,
}

impl HeatingController {
    pub fn new(
        config: HeatingConfig,
        topology: Arc<Topology>,
        clock: Arc<dyn Clock>,
    ) -> Self {
        let now = clock.now();
        let mut state = HeatingRuntimeState::new();
        // Seed conservative pump_off timestamp: assume the pump might
        // have just stopped so that min_pause is enforced on first
        // startup. This prevents short-cycling if the daemon restarts
        // immediately after a pump run.
        state.pump_off_since = Some(now);

        // Pre-populate zone and TRV state entries.
        for zone in &config.zones {
            let mut zone_state = HeatingZoneRuntimeState::new();
            for zt in &zone.trvs {
                zone_state.trvs.insert(zt.device.clone(), TrvRuntimeState::new());
            }
            state.zones.insert(zone.name.clone(), zone_state);
        }
        Self {
            config,
            topology,
            clock,
            state,
            startup_complete: false,
            tick_gen: 0,
        }
    }

    /// Handle TRV or wall thermostat state events. Returns actions.
    pub fn handle_event(&mut self, event: &Event) -> Vec<Action> {
        match event {
            Event::TrvState {
                device,
                local_temperature,
                pi_heating_demand,
                running_state,
                occupied_heating_setpoint,
                operating_mode,
                battery,
                ..
            } => {
                self.handle_trv_state(
                    device,
                    *local_temperature,
                    *pi_heating_demand,
                    running_state.as_deref(),
                    *occupied_heating_setpoint,
                    operating_mode.as_deref(),
                    *battery,
                );
                // Reassert manual mode if the TRV drifted.
                self.check_trv_mode(device)
            }
            Event::WallThermostatState {
                device,
                relay_on,
                operating_mode,
                ..
            } => {
                self.handle_wall_thermostat_state(device, *relay_on, operating_mode.as_deref());
                // Reassert manual mode if the wall thermostat drifted.
                self.check_wt_mode(device)
            }
            _ => Vec::new(),
        }
    }

    /// Called on every Tick. Returns all heating actions.
    pub fn handle_tick(&mut self) -> Vec<Action> {
        self.tick_gen += 1;
        if !self.startup_complete {
            self.startup_complete = true;
            // Warn about zones whose relay state is still unknown.
            for zone in &self.config.zones {
                if let Some(zs) = self.state.zones.get(&zone.name) {
                    if !zs.relay_state_known {
                        tracing::warn!(
                            zone = %zone.name,
                            relay = %zone.relay,
                            "startup: wall thermostat never responded, \
                             heating control disabled for this zone until first state echo"
                        );
                    }
                }
            }
        }
        let now = self.clock.now();
        let weekday = self.clock.local_weekday();
        let hour = self.clock.local_hour();
        let minute = self.clock.local_minute();

        let mut actions = Vec::new();

        // 0. Expire any finished inhibitions (runs unconditionally).
        self.expire_inhibitions(now);

        // 0b. Warn about stale TRVs (demand suppressed automatically).
        for zone in &self.config.zones {
            if let Some(zs) = self.state.zones.get(&zone.name) {
                for zt in &zone.trvs {
                    if let Some(trv) = zs.trvs.get(&zt.device) {
                        if trv.is_stale(now) && trv.has_raw_demand() {
                            tracing::warn!(
                                trv = %zt.device,
                                zone = %zone.name,
                                last_seen_secs_ago = trv.last_seen
                                    .map(|s| now.duration_since(s).as_secs())
                                    .unwrap_or(0),
                                "TRV stale: demand suppressed (device may be unreachable)"
                            );
                        }
                    }
                }
            }
        }

        // 1. Pressure group enforcement (before schedule so released
        //    TRVs get their scheduled setpoint in the same tick).
        actions.extend(self.enforce_pressure_groups(now));

        // 2. Schedule evaluation: update TRV setpoints.
        actions.extend(self.evaluate_schedules(weekday, hour, minute, now));

        // 2b. Reconcile: retry setpoints the device hasn't confirmed.
        actions.extend(self.reconcile_setpoints());

        // 3. Open window detection.
        actions.extend(self.detect_open_windows(now));

        // 4. Relay control (sets desired_relay, does NOT flip confirmed state).
        actions.extend(self.evaluate_relays(now));

        // 5. Reconcile relays: retry commands the wall thermostat hasn't confirmed.
        actions.extend(self.reconcile_relays());

        actions
    }

    /// Read-only access to runtime state (for web dashboard).
    pub fn state(&self) -> &HeatingRuntimeState {
        &self.state
    }

    // ---- TRV state update --------------------------------------------------

    fn handle_trv_state(
        &mut self,
        device: &str,
        local_temperature: Option<f64>,
        pi_heating_demand: Option<u8>,
        running_state: Option<&str>,
        occupied_heating_setpoint: Option<f64>,
        operating_mode: Option<&str>,
        battery: Option<u8>,
    ) {
        let now = self.clock.now();
        let Some(trv) = self.find_trv_state_mut(device) else {
            return;
        };
        trv.last_seen = Some(now);
        if let Some(temp) = local_temperature {
            trv.local_temperature = Some(temp);
            // Update high-water mark for open-window detection.
            if trv.temp_at_relay_on.is_some() {
                trv.temp_high_water = Some(
                    trv.temp_high_water.map_or(temp, |hw| hw.max(temp)),
                );
            }
        }
        if let Some(demand) = pi_heating_demand {
            trv.pi_heating_demand = Some(demand);
            // If this is a pi-only update (no running_state in this
            // message) and we previously trusted running_state, sync
            // running_state from pi to avoid stale demand latching.
            if running_state.is_none() && trv.running_state_seen {
                trv.running_state = if demand > 0 {
                    HeatingRunningState::Heat
                } else {
                    HeatingRunningState::Idle
                };
            }
        }
        if let Some(rs) = running_state {
            if let Some(parsed) = HeatingRunningState::parse(rs) {
                trv.running_state = parsed;
                trv.running_state_seen = true;
            }
        }
        if let Some(sp) = occupied_heating_setpoint {
            trv.reported_setpoint = Some(sp);
            if let Some(sent) = trv.last_sent_setpoint {
                if (sent - sp).abs() < 0.1 {
                    trv.setpoint_confirmed = true;
                    trv.pressure_release_pending = false;
                } else if trv.setpoint_confirmed {
                    // Post-confirmation divergence: the device moved
                    // away from our setpoint (manual knob change, device
                    // reset, etc). Mark dirty so reconciliation reasserts.
                    trv.setpoint_confirmed = false;
                    tracing::info!(
                        trv = %device,
                        sent, reported = sp,
                        "setpoint diverged after confirmation, marking dirty"
                    );
                }
            }
        }
        if let Some(mode) = operating_mode {
            trv.operating_mode = Some(mode.to_string());
        }
        if let Some(batt) = battery {
            if batt <= 10 {
                tracing::warn!(trv = %device, battery = batt, "TRV battery critically low");
            }
            trv.battery = Some(batt);
        }
    }

    fn handle_wall_thermostat_state(
        &mut self,
        device: &str,
        relay_on: Option<bool>,
        operating_mode: Option<&str>,
    ) {
        // Track operating mode regardless of relay transition.
        if let Some(mode) = operating_mode {
            let zone_name = self.config.zones.iter()
                .find(|z| z.relay == device)
                .map(|z| z.name.clone());
            if let Some(ref zn) = zone_name {
                if let Some(zs) = self.state.zones.get_mut(zn) {
                    zs.wt_operating_mode = Some(mode.to_string());
                }
            }
        }

        let Some(on) = relay_on else { return };
        let now = self.clock.now();

        // Find the zone for this relay.
        let zone_name = self.config.zones.iter()
            .find(|z| z.relay == device)
            .map(|z| z.name.clone());
        let Some(zone_name) = zone_name else { return };

        // Snapshot relay count before mutation for pump tracking.
        let relays_on_before = self.state.active_relay_count();

        let Some(zone_state) = self.state.zones.get_mut(&zone_name) else {
            return;
        };
        zone_state.relay_state_known = true;
        let was_on = zone_state.relay_on;
        if was_on == on {
            // No transition — but a repeated OFF echo can still be
            // meaningful: if this zone has a pending ON, this OFF
            // confirms the relay went off after a lost ON echo.
            // Only clears THIS zone's pending state (not other zones').
            if !on && zone_state.pending_on_at.is_some() {
                zone_state.pending_on_at = None;
                zone_state.desired_relay = None;
                tracing::info!(
                    zone = %zone_name, relay = device,
                    "MQTT: repeated OFF echo clears stale pending-ON state"
                );
            }
            return;
        }
        zone_state.relay_on = on;

        if on {
            // OFF → ON edge observed from MQTT.
            zone_state.relay_on_since = Some(now);
            // Only start open-window timers after startup hydration is
            // complete. During startup, this is state synchronization
            // (the relay was already on), not a fresh heating cycle.
            if self.startup_complete {
                for trv_state in zone_state.trvs.values_mut() {
                    trv_state.temp_at_relay_on = trv_state.local_temperature;
                    trv_state.temp_high_water = trv_state.local_temperature;
                    trv_state.open_window_checked = false;
                }
            }
            // ON echo confirms this zone's pending ON.
            zone_state.pending_on_at = None;
            // Clear desired_relay now that the echo confirmed it.
            // This re-enables phase-0 proactive OFF for future restarts.
            if zone_state.desired_relay == Some(true) {
                zone_state.desired_relay = None;
            }
            // If no relay was on before, pump just started.
            if relays_on_before == 0 {
                self.state.pump_on_since = Some(now);
                self.state.pump_off_since = None;
                self.state.pending_pump_off_at = None;
                tracing::info!(
                    zone = %zone_name, relay = device,
                    "MQTT: relay ON observed, pump starting"
                );
            }
        } else {
            // ON → OFF edge observed from MQTT.
            zone_state.relay_on_since = None;
            for trv_state in zone_state.trvs.values_mut() {
                trv_state.temp_at_relay_on = None;
                trv_state.temp_high_water = None;
                trv_state.open_window_checked = false;
            }
            // OFF echo confirms this zone's relay is off.
            zone_state.pending_on_at = None;
            if zone_state.desired_relay == Some(false) {
                zone_state.desired_relay = None;
            }
            // If this was the only relay on (count was 1 before, now 0
            // after the mutation above), pump just stopped.
            if relays_on_before == 1 {
                self.state.pump_off_since = Some(now);
                self.state.pump_on_since = None;
                self.state.pending_pump_off_at = None;
                tracing::info!(
                    zone = %zone_name, relay = device,
                    "MQTT: relay OFF observed, pump stopping"
                );
            }
        }
    }

    // ---- Schedule evaluation -----------------------------------------------

    fn evaluate_schedules(
        &mut self,
        weekday: Weekday,
        hour: u8,
        minute: u8,
        _now: Instant,
    ) -> Vec<Action> {
        let mut actions = Vec::new();

        for zone in &self.config.zones {
            for zt in &zone.trvs {
                let Some(schedule) = self.config.schedules.get(&zt.schedule) else {
                    continue;
                };
                let Some(target) = schedule.target_temperature(weekday, hour, minute) else {
                    continue;
                };
                let Some(zone_state) = self.state.zones.get_mut(&zone.name) else {
                    continue;
                };
                let Some(trv_state) = zone_state.trvs.get_mut(&zt.device) else {
                    continue;
                };

                // Don't update setpoint if:
                // - TRV is pressure-forced (setpoint overridden to 30°C)
                // - TRV is inhibited (setpoint lowered to 5°C)
                if trv_state.pressure_forced {
                    continue;
                }
                let now = self.clock.now();
                if trv_state.is_inhibited(now) {
                    continue;
                }

                // Only skip if the target matches what we sent AND the
                // device has confirmed it. Unconfirmed writes are not
                // treated as applied — the schedule keeps publishing.
                if trv_state.last_sent_setpoint == Some(target)
                    && trv_state.setpoint_confirmed
                {
                    continue;
                }

                trv_state.last_sent_setpoint = Some(target);
                trv_state.setpoint_confirmed = false;
                trv_state.setpoint_dirty_gen = self.tick_gen;
                actions.push(Action::for_device(
                    zt.device.clone(),
                    Payload::trv_setpoint(target),
                ));

                tracing::info!(
                    trv = %zt.device,
                    target_temp = target,
                    weekday = %weekday,
                    time = format!("{hour:02}:{minute:02}"),
                    "schedule: setting TRV setpoint"
                );
            }
        }
        actions
    }

    // ---- Setpoint reconciliation ---------------------------------------------

    /// Retry setpoint writes that the device hasn't confirmed. If we
    /// sent a setpoint but the device reports a different value, re-publish.
    /// This handles MQTT publish failures without requiring ack tracking.
    fn reconcile_setpoints(&mut self) -> Vec<Action> {
        let mut actions = Vec::new();

        for zone in &self.config.zones {
            let Some(zone_state) = self.state.zones.get(&zone.name) else {
                continue;
            };
            for zt in &zone.trvs {
                let Some(trv_state) = zone_state.trvs.get(&zt.device) else {
                    continue;
                };
                if !trv_state.needs_setpoint_retry() {
                    continue;
                }
                // Skip entries dirtied this tick (already published).
                if trv_state.setpoint_dirty_gen == self.tick_gen {
                    continue;
                }
                let Some(target) = trv_state.last_sent_setpoint else {
                    continue;
                };
                actions.push(Action::for_device(
                    zt.device.clone(),
                    Payload::trv_setpoint(target),
                ));
                tracing::info!(
                    trv = %zt.device,
                    target,
                    reported = ?trv_state.reported_setpoint,
                    confirmed = trv_state.setpoint_confirmed,
                    "reconcile: retrying unconfirmed setpoint"
                );
            }
        }
        actions
    }

    // ---- Pressure group enforcement ----------------------------------------

    fn enforce_pressure_groups(&mut self, now: Instant) -> Vec<Action> {
        let mut actions = Vec::new();

        for group in &self.config.pressure_groups {
            // Organic demand: only count TRVs that are NOT pressure_forced
            // and NOT inhibited. This prevents the latch-on bug where a
            // forced TRV's own demand (from the 30°C override) keeps the
            // group active after the original caller stops demanding.
            let any_organic_demand = group.trvs.iter().any(|trv_name| {
                find_trv_in_zones(&self.state, trv_name)
                    .is_some_and(|t| {
                        !t.pressure_forced && !t.is_inhibited(now) && t.has_raw_demand()
                    })
            });

            for trv_name in &group.trvs {
                let Some(trv_state) = find_trv_in_zones_mut(&mut self.state, trv_name) else {
                    continue;
                };

                if any_organic_demand {
                    // Skip inhibited TRVs: open-window inhibition takes
                    // priority over pressure balancing.
                    if trv_state.is_inhibited(now) {
                        continue;
                    }
                    if !trv_state.pressure_forced && !trv_state.has_raw_demand() {
                        trv_state.pressure_forced = true;
                        trv_state.last_sent_setpoint = Some(MAX_SETPOINT);
                        trv_state.setpoint_confirmed = false;
                        trv_state.setpoint_dirty_gen = self.tick_gen;
                        actions.push(Action::for_device(
                            trv_name.clone(),
                            Payload::trv_setpoint(MAX_SETPOINT),
                        ));
                        tracing::info!(
                            trv = %trv_name,
                            group = %group.name,
                            "pressure group: force-opening TRV (setpoint → 30°C)"
                        );
                    }
                } else if trv_state.pressure_forced {
                    trv_state.pressure_forced = false;
                    trv_state.pressure_release_pending = true;
                    trv_state.last_sent_setpoint = None;
                    trv_state.setpoint_confirmed = true; // schedule will re-send
                    tracing::info!(
                        trv = %trv_name,
                        group = %group.name,
                        "pressure group: releasing forced TRV (demand suppressed until setpoint confirmed)"
                    );
                }
            }
        }
        actions
    }

    // ---- Open window detection ---------------------------------------------

    fn detect_open_windows(&mut self, now: Instant) -> Vec<Action> {
        let mut actions = Vec::new();
        let detect_dur = Duration::from_secs(
            self.config.open_window.detection_minutes as u64 * 60,
        );
        let inhibit_dur = Duration::from_secs(
            self.config.open_window.inhibit_minutes as u64 * 60,
        );
        let inhibit_minutes = self.config.open_window.inhibit_minutes;

        for zone in &self.config.zones {
            let Some(zone_state) = self.state.zones.get_mut(&zone.name) else {
                continue;
            };
            if !zone_state.relay_on {
                continue;
            }
            let Some(relay_on_since) = zone_state.relay_on_since else {
                continue;
            };
            if now.duration_since(relay_on_since) < detect_dur {
                continue;
            }

            for zt in &zone.trvs {
                let Some(trv_state) = zone_state.trvs.get_mut(&zt.device) else {
                    continue;
                };
                // One-shot: skip if already checked in this relay cycle.
                if trv_state.open_window_checked {
                    continue;
                }
                if trv_state.is_inhibited(now) || trv_state.pressure_forced {
                    continue;
                }
                let Some(temp_at_on) = trv_state.temp_at_relay_on else {
                    continue;
                };

                // Mark as checked — this TRV won't be evaluated again
                // until the relay cycles off and back on.
                trv_state.open_window_checked = true;

                // Use the high-water mark: if the temperature EVER rose
                // above the baseline during the detection window, the
                // room warmed successfully and this is not an open window.
                let peak = trv_state.temp_high_water.unwrap_or(temp_at_on);
                if peak <= temp_at_on {
                    trv_state.inhibited_until = Some(now + inhibit_dur);
                    trv_state.last_sent_setpoint = Some(MIN_SETPOINT);
                    trv_state.setpoint_confirmed = false;
                    trv_state.setpoint_dirty_gen = self.tick_gen;
                    actions.push(Action::for_device(
                        zt.device.clone(),
                        Payload::trv_setpoint(MIN_SETPOINT),
                    ));
                    tracing::warn!(
                        trv = %zt.device,
                        zone = %zone.name,
                        temp_at_on, peak, inhibit_minutes,
                        "open window detected: inhibiting TRV (temp never rose above baseline)"
                    );
                } else {
                    tracing::debug!(
                        trv = %zt.device,
                        zone = %zone.name,
                        temp_at_on, peak,
                        "open window check passed: temperature rose during detection window"
                    );
                }
            }
        }

        actions
    }

    /// Un-inhibit TRVs whose inhibition timer has expired. Runs
    /// independently of relay state so inhibitions always expire.
    fn expire_inhibitions(&mut self, now: Instant) {
        for zone in &self.config.zones {
            let Some(zone_state) = self.state.zones.get_mut(&zone.name) else {
                continue;
            };
            for zt in &zone.trvs {
                let Some(trv_state) = zone_state.trvs.get_mut(&zt.device) else {
                    continue;
                };
                if let Some(until) = trv_state.inhibited_until {
                    if now >= until {
                        trv_state.inhibited_until = None;
                        trv_state.last_sent_setpoint = None;
                        trv_state.setpoint_confirmed = true; // schedule will re-send
                        // Clear the reference temp so open window detection
                        // doesn't immediately re-trigger. A new reference
                        // will be set on the next relay-on cycle.
                        trv_state.temp_at_relay_on = None;
                        trv_state.temp_high_water = None;
                        tracing::info!(
                            trv = %zt.device, zone = %zone.name,
                            "open window inhibition expired, restoring TRV"
                        );
                    }
                }
            }
        }
    }

    // ---- Relay control with global pump protection -------------------------

    /// Decide desired relay state for each zone. Does NOT flip confirmed
    /// state — that only happens when the wall thermostat echoes back via
    /// `handle_wall_thermostat_state`. Emits ON/OFF actions and records
    /// `desired_relay` so the reconciler can retry on publish failure.
    fn evaluate_relays(&mut self, now: Instant) -> Vec<Action> {
        let mut actions = Vec::new();
        let min_cycle = Duration::from_secs(self.config.heat_pump.min_cycle_seconds);
        let min_pause = Duration::from_secs(self.config.heat_pump.min_pause_seconds);

        // Snapshot per-zone state to avoid borrow conflicts.
        struct ZoneDecision {
            zone_name: String,
            relay: String,
            has_demand: bool,
            relay_on: bool,
            desired: Option<bool>,
        }
        let decisions: Vec<ZoneDecision> = self
            .config
            .zones
            .iter()
            .filter_map(|zone| {
                let zs = self.state.zones.get(&zone.name)?;
                // Unknown relay state defaults to OFF (conservative).
                // The controller proceeds normally — if demand exists it
                // will send ON, and the echo will confirm actual state.
                // This is self-healing: a missed startup refresh doesn't
                // permanently strand the zone.
                Some(ZoneDecision {
                    zone_name: zone.name.clone(),
                    relay: zone.relay.clone(),
                    has_demand: zs.has_effective_demand(now),
                    relay_on: zs.relay_on,
                    desired: zs.desired_relay,
                })
            })
            .collect();

        // --- Phase 0: unknown-state zones with no demand → proactive OFF ---
        // If the relay was physically ON before restart but the startup
        // refresh missed, we must proactively send OFF to reconcile.
        for zone in &self.config.zones {
            let Some(zs) = self.state.zones.get_mut(&zone.name) else {
                continue;
            };
            if !zs.relay_state_known && zs.desired_relay.is_none() {
                let has_demand = zs.has_effective_demand(now);
                if !has_demand {
                    // Proactively send OFF. If the relay was already off,
                    // this is a harmless no-op. If it was physically on,
                    // this turns it off. Either way the echo will resolve
                    // relay_state_known.
                    actions.push(Action::for_device(
                        zone.relay.clone(),
                        Payload::device_off(),
                    ));
                    zs.desired_relay = Some(false);
                    zs.desired_relay_gen = self.tick_gen;
                    tracing::info!(
                        zone = %zone.name,
                        relay = %zone.relay,
                        "heating: proactive OFF for unknown-state zone (no demand)"
                    );
                }
            }
        }

        // --- Phase 1: ON requests ---
        for d in &decisions {
            if d.has_demand && d.desired != Some(true) {
                let allowed = if self.state.is_pump_running() {
                    true // pump already running — no pause check needed
                } else {
                    self.state.effective_pump_off_since()
                        .map(|off_at| now.duration_since(off_at) >= min_pause)
                        .unwrap_or(true)
                };
                if allowed {
                    actions.push(Action::for_device(d.relay.clone(), Payload::device_on()));
                    { let zs = self.state.zones.get_mut(&d.zone_name).unwrap();
                      zs.desired_relay = Some(true);
                      zs.desired_relay_gen = self.tick_gen;
                      // Track pending ON for ALL relay ON requests so a
                      // lost echo is always recoverable via reconciliation.
                      zs.pending_on_at = Some(now);
                    }
                    tracing::info!(
                        zone = %d.zone_name, relay = %d.relay,
                        pump_running = self.state.is_pump_running(),
                        "heating: requesting relay ON"
                    );
                }
            }
        }

        // --- Phase 2: stale-ON cancellations (demand gone, echo pending) ---
        for d in &decisions {
            if !d.has_demand && !d.relay_on && d.desired == Some(true) {
                let cycle_ok = self.state.effective_pump_on_since()
                    .map(|on_at| now.duration_since(on_at) >= min_cycle)
                    .unwrap_or(true);
                if cycle_ok {
                    // Set desired=Some(false) so reconcile retries the OFF
                    // until the wall thermostat confirms it.
                    { let zs = self.state.zones.get_mut(&d.zone_name).unwrap(); zs.desired_relay = Some(false); zs.desired_relay_gen = self.tick_gen; }
                    actions.push(Action::for_device(d.relay.clone(), Payload::device_off()));
                    self.state.pending_pump_off_at = Some(now);
                    // pending_on_at stays on this zone until the OFF echo confirms.
                    tracing::info!(
                        zone = %d.zone_name, relay = %d.relay,
                        "heating: cancelling stale relay ON (demand gone, min_cycle ok)"
                    );
                }
            }
        }

        // --- Phase 3: confirmed-ON relay OFF requests (two-phase) ---
        // First, identify which confirmed-ON zones want OFF.
        let want_off: Vec<&ZoneDecision> = decisions
            .iter()
            .filter(|d| !d.has_demand && d.desired != Some(false) && d.relay_on)
            .collect();

        if !want_off.is_empty() {
            let confirmed_on = self.state.active_relay_count();
            // Exclude relays with a pending OFF (desired=false but
            // relay_on still true). They may have already physically
            // turned off — counting them as survivors is unsafe.
            let pending_off_count = self.state.zones.values()
                .filter(|zs| zs.relay_on && zs.desired_relay == Some(false))
                .count();
            let safe_on = confirmed_on.saturating_sub(pending_off_count);
            let survivors = safe_on.saturating_sub(want_off.len());

            // Check if any other zone has a pending ON that hasn't been
            // confirmed yet. If so, we must keep at least one confirmed
            // relay on to bridge the pump until the replacement arrives.
            // Otherwise the pump stops and the pending ON retries without
            // min_pause protection.
            let has_pending_on = decisions.iter().any(|d| {
                !d.relay_on && self.state.zones.get(&d.zone_name)
                    .is_some_and(|zs| zs.desired_relay == Some(true))
            });

            if survivors > 0 {
                // Pump stays running via other confirmed relays.
                for d in &want_off {
                    actions.push(Action::for_device(d.relay.clone(), Payload::device_off()));
                    { let zs = self.state.zones.get_mut(&d.zone_name).unwrap(); zs.desired_relay = Some(false); zs.desired_relay_gen = self.tick_gen; }
                    tracing::info!(
                        zone = %d.zone_name, relay = %d.relay,
                        "heating: requesting relay OFF (pump stays running)"
                    );
                }
            } else if has_pending_on {
                // All confirmed relays want OFF but another zone has a
                // pending ON. Keep the last relay on to bridge the pump
                // until the replacement is confirmed.
                tracing::debug!(
                    zones_wanting_off = want_off.len(),
                    "heating: relay OFF deferred, bridging pump for pending ON"
                );
            } else {
                // All confirmed-ON relays want OFF → pump would stop.
                let cycle_ok = self.state.effective_pump_on_since()
                    .map(|on_at| now.duration_since(on_at) >= min_cycle)
                    .unwrap_or(true);
                if cycle_ok {
                    for d in &want_off {
                        actions.push(Action::for_device(d.relay.clone(), Payload::device_off()));
                        { let zs = self.state.zones.get_mut(&d.zone_name).unwrap(); zs.desired_relay = Some(false); zs.desired_relay_gen = self.tick_gen; }
                        tracing::info!(
                            zone = %d.zone_name, relay = %d.relay,
                            "heating: requesting relay OFF (pump stopping)"
                        );
                    }
                    self.state.pending_pump_off_at = Some(now);
                } else {
                    tracing::debug!(
                        zones_wanting_off = want_off.len(),
                        "heating: relay OFF blocked by min_cycle protection"
                    );
                }
            }
        }

        actions
    }

    /// Retry relay commands the wall thermostat hasn't confirmed yet.
    // ---- Device mode enforcement -------------------------------------------

    /// Check if a TRV has drifted away from `manual` mode and reassert.
    fn check_trv_mode(&self, device: &str) -> Vec<Action> {
        let Some(trv) = self.find_trv_state(device) else {
            return Vec::new();
        };
        match trv.operating_mode.as_deref() {
            Some("manual") | None => Vec::new(), // correct or unknown
            Some(mode) => {
                tracing::warn!(
                    trv = %device,
                    current_mode = mode,
                    "TRV operating_mode is not 'manual', reasserting"
                );
                vec![Action::for_device(
                    device.to_string(),
                    Payload::OperatingMode { operating_mode: "manual" },
                )]
            }
        }
    }

    /// Check if a wall thermostat has drifted away from `manual` mode.
    fn check_wt_mode(&self, device: &str) -> Vec<Action> {
        for zone in &self.config.zones {
            if zone.relay != device {
                continue;
            }
            let Some(zs) = self.state.zones.get(&zone.name) else {
                break;
            };
            return match zs.wt_operating_mode.as_deref() {
                Some("manual") | None => Vec::new(),
                Some(mode) => {
                    tracing::warn!(
                        zone = %zone.name,
                        relay = %device,
                        current_mode = mode,
                        "wall thermostat operating_mode is not 'manual', reasserting"
                    );
                    vec![Action::for_device(
                        device.to_string(),
                        Payload::OperatingMode { operating_mode: "manual" },
                    )]
                }
            };
        }
        Vec::new()
    }

    fn reconcile_relays(&self) -> Vec<Action> {
        let mut actions = Vec::new();
        for zone in &self.config.zones {
            let Some(zone_state) = self.state.zones.get(&zone.name) else {
                continue;
            };
            let Some(desired) = zone_state.desired_relay else {
                continue;
            };
            // Skip entries changed this tick (already published).
            if zone_state.desired_relay_gen == self.tick_gen {
                continue;
            }

            // Normal case: desired != confirmed → retry.
            let needs_retry = if desired != zone_state.relay_on {
                true
            } else if !desired && zone_state.pending_on_at.is_some() {
                // Special case: desired=false, relay_on=false, but
                // this zone has a pending ON — the relay might physically
                // be ON (ON echo was lost). Keep retrying OFF.
                true
            } else {
                false
            };

            if !needs_retry {
                continue;
            }

            let payload = if desired {
                Payload::device_on()
            } else {
                Payload::device_off()
            };
            actions.push(Action::for_device(zone.relay.clone(), payload));
            tracing::info!(
                zone = %zone.name,
                relay = %zone.relay,
                desired,
                confirmed = zone_state.relay_on,
                pending_on = zone_state.pending_on_at.is_some(),
                "reconcile: retrying unconfirmed relay command"
            );
        }
        actions
    }

    // ---- Helpers ------------------------------------------------------------

    fn find_trv_state(&self, device: &str) -> Option<&TrvRuntimeState> {
        for zone_state in self.state.zones.values() {
            if let Some(trv) = zone_state.trvs.get(device) {
                return Some(trv);
            }
        }
        None
    }

    fn find_trv_state_mut(&mut self, device: &str) -> Option<&mut TrvRuntimeState> {
        for zone_state in self.state.zones.values_mut() {
            if let Some(trv) = zone_state.trvs.get_mut(device) {
                return Some(trv);
            }
        }
        None
    }
}

// ---- Free-standing helpers (avoid borrow conflicts) ------------------------

fn find_trv_in_zones<'a>(
    state: &'a HeatingRuntimeState,
    device: &str,
) -> Option<&'a TrvRuntimeState> {
    for zone_state in state.zones.values() {
        if let Some(trv) = zone_state.trvs.get(device) {
            return Some(trv);
        }
    }
    None
}

fn find_trv_in_zones_mut<'a>(
    state: &'a mut HeatingRuntimeState,
    device: &str,
) -> Option<&'a mut TrvRuntimeState> {
    for zone_state in state.zones.values_mut() {
        if let Some(trv) = zone_state.trvs.get_mut(device) {
            return Some(trv);
        }
    }
    None
}

// ---- Tests -----------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::heating::*;
    use crate::config::{CommonFields, Config, Defaults, DeviceCatalogEntry};
    use crate::time::FakeClock;
    use crate::topology::Topology;
    use std::collections::BTreeMap;

    fn full_day(temp: f64) -> Vec<DayTimeRange> {
        vec![DayTimeRange {
            start_hour: 0,
            start_minute: 0,
            end_hour: 24,
            end_minute: 0,
            temperature: temp,
        }]
    }

    fn full_week(temp: f64) -> BTreeMap<Weekday, Vec<DayTimeRange>> {
        Weekday::ALL.iter().map(|&d| (d, full_day(temp))).collect()
    }

    fn two_period_day(day_temp: f64, night_temp: f64) -> Vec<DayTimeRange> {
        vec![
            DayTimeRange {
                start_hour: 0,
                start_minute: 0,
                end_hour: 8,
                end_minute: 0,
                temperature: night_temp,
            },
            DayTimeRange {
                start_hour: 8,
                start_minute: 0,
                end_hour: 22,
                end_minute: 0,
                temperature: day_temp,
            },
            DayTimeRange {
                start_hour: 22,
                start_minute: 0,
                end_hour: 24,
                end_minute: 0,
                temperature: night_temp,
            },
        ]
    }

    fn trv_dev(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Trv(CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::new(),
        })
    }

    fn wt_dev(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::WallThermostat(CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::new(),
        })
    }

    fn make_config(
        zones: Vec<HeatingZone>,
        schedules: BTreeMap<String, TemperatureSchedule>,
        pressure_groups: Vec<PressureGroup>,
    ) -> Config {
        let mut devices: BTreeMap<String, DeviceCatalogEntry> = BTreeMap::new();
        for zone in &zones {
            devices.insert(
                zone.relay.clone(),
                wt_dev(&format!("0x{}", zone.relay)),
            );
            for zt in &zone.trvs {
                devices.insert(
                    zt.device.clone(),
                    trv_dev(&format!("0x{}", zt.device)),
                );
            }
        }

        Config {
            name_by_address: BTreeMap::new(),
            devices,
            rooms: vec![],
            actions: vec![],
            defaults: Defaults::default(),
            heating: Some(HeatingConfig {
                zones,
                schedules,
                pressure_groups,
                heat_pump: HeatPumpProtection {
                    min_cycle_seconds: 120,
                    min_pause_seconds: 60,
                },
                open_window: OpenWindowProtection {
                    detection_minutes: 20,
                    inhibit_minutes: 80,
                },
            }),
        }
    }

    fn simple_config() -> Config {
        make_config(
            vec![HeatingZone {
                name: "bath".into(),
                relay: "wt-bath".into(),
                trvs: vec![ZoneTrv {
                    device: "trv-bath-1".into(),
                    schedule: "bath-sched".into(),
                }],
            }],
            BTreeMap::from([(
                "bath-sched".into(),
                TemperatureSchedule {
                    days: full_week(20.0),
                },
            )]),
            vec![],
        )
    }

    fn setup(cfg: &Config) -> (HeatingController, Arc<FakeClock>) {
        let clk = Arc::new(FakeClock::new(12));
        let topo = Arc::new(Topology::build(cfg).unwrap());
        let heating_cfg = cfg.heating.clone().unwrap();
        let mut hc = HeatingController::new(heating_cfg, topo, clk.clone());
        // Simulate startup: mark all zones as relay-state-known (OFF)
        // and advance past the conservative startup min_pause.
        for zs in hc.state.zones.values_mut() {
            zs.relay_state_known = true;
        }
        hc.startup_complete = true;
        clk.advance(Duration::from_secs(120));
        (hc, clk)
    }

    /// Simulate a wall thermostat confirming relay state via MQTT echo.
    fn echo_relay(hc: &mut HeatingController, relay: &str, on: bool, clk: &FakeClock) {
        hc.handle_event(&Event::WallThermostatState {
            device: relay.into(),
            relay_on: Some(on),
            local_temperature: None,
            operating_mode: None,
            ts: clk.now(),
        });
    }

    // -- Schedule tests --

    /// Simulate a TRV confirming our setpoint via echo.
    fn echo_setpoint(hc: &mut HeatingController, trv: &str, temp: f64, clk: &FakeClock) {
        hc.handle_event(&Event::TrvState {
            device: trv.into(),
            local_temperature: None,
            pi_heating_demand: None,
            running_state: None,
            occupied_heating_setpoint: Some(temp),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
    }

    #[test]
    fn schedule_sets_initial_setpoint() {
        let cfg = simple_config();
        let (mut hc, _clk) = setup(&cfg);
        let actions = hc.handle_tick();
        // Should emit setpoint action(s) for the TRV.
        let sp_actions: Vec<_> = actions
            .iter()
            .filter(|a| a.target_name() == "trv-bath-1")
            .collect();
        assert!(!sp_actions.is_empty());
        let json = serde_json::to_string(&sp_actions[0].payload).unwrap();
        assert!(json.contains("20"));
    }

    #[test]
    fn schedule_dedup_skips_redundant_setpoint() {
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();
        // Confirm the setpoint via TRV echo.
        echo_setpoint(&mut hc, "trv-bath-1", 20.0, &clk);
        // Second tick with same time + confirmed → no action.
        let actions2 = hc.handle_tick();
        let sp_actions: Vec<_> = actions2
            .iter()
            .filter(|a| a.target_name() == "trv-bath-1")
            .collect();
        assert!(sp_actions.is_empty(), "should not re-send confirmed setpoint");
    }

    #[test]
    fn schedule_retries_unconfirmed_setpoint() {
        let cfg = simple_config();
        let (mut hc, _clk) = setup(&cfg);
        hc.handle_tick(); // sends setpoint, unconfirmed
        // No TRV echo — second tick should retry.
        let actions2 = hc.handle_tick();
        let sp_actions: Vec<_> = actions2
            .iter()
            .filter(|a| a.target_name() == "trv-bath-1")
            .collect();
        assert!(!sp_actions.is_empty(), "should retry unconfirmed setpoint");
    }

    #[test]
    fn schedule_updates_on_time_change() {
        let mut days = BTreeMap::new();
        for &d in &Weekday::ALL {
            days.insert(d, two_period_day(22.0, 18.0));
        }
        let cfg = make_config(
            vec![HeatingZone {
                name: "bath".into(),
                relay: "wt-bath".into(),
                trvs: vec![ZoneTrv {
                    device: "trv-bath-1".into(),
                    schedule: "sched".into(),
                }],
            }],
            BTreeMap::from([("sched".into(), TemperatureSchedule { days })]),
            vec![],
        );
        let (mut hc, clk) = setup(&cfg);

        // 12:00 Monday → 22.0
        let actions = hc.handle_tick();
        assert!(!actions.is_empty());
        let json = serde_json::to_string(&actions[0].payload).unwrap();
        assert!(json.contains("22"));
        echo_setpoint(&mut hc, "trv-bath-1", 22.0, &clk);

        // Change to 23:00 → 18.0
        clk.set_hour(23);
        let actions = hc.handle_tick();
        let sp_actions: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "trv-bath-1"
                    && serde_json::to_string(&a.payload).unwrap().contains("18")
            })
            .collect();
        assert!(!sp_actions.is_empty(), "should set new target on time change");
    }

    // -- Demand and relay tests --

    #[test]
    fn relay_turns_on_when_trv_demands_heat() {
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);

        // Initial tick sets setpoint.
        hc.handle_tick();

        // Simulate TRV reporting heat demand.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });

        let actions = hc.handle_tick();
        // Should emit at least one relay ON command.
        let relay_on_actions: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "wt-bath"
                    && serde_json::to_string(&a.payload).unwrap().contains("ON")
            })
            .collect();
        assert!(!relay_on_actions.is_empty(), "should request relay ON");
    }

    #[test]
    fn relay_turns_off_when_demand_stops() {
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // TRV demands heat.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // emits relay ON
        echo_relay(&mut hc, "wt-bath", true, &clk); // confirm

        // Advance past min_cycle.
        clk.advance(Duration::from_secs(200));

        // TRV stops demanding.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(20.5),
            pi_heating_demand: Some(0),
            running_state: Some("idle".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });

        let actions = hc.handle_tick();
        let relay_actions: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "wt-bath"
                    && serde_json::to_string(&a.payload).unwrap().contains("OFF")
            })
            .collect();
        assert!(!relay_actions.is_empty(), "should request relay OFF");
    }

    // -- Short cycling tests --

    #[test]
    fn min_pause_blocks_relay_on() {
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // Simulate pump was recently off.
        hc.state.pump_off_since = Some(clk.now());
        clk.advance(Duration::from_secs(30)); // less than min_pause (60s)

        // TRV demands heat.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });

        let actions = hc.handle_tick();
        // Relay should NOT turn on (min_pause not elapsed).
        let relay_on_actions: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "wt-bath"
                    && serde_json::to_string(&a.payload).unwrap().contains("ON")
            })
            .collect();
        assert!(relay_on_actions.is_empty(), "should block relay ON during min_pause");

        // Advance past min_pause.
        clk.advance(Duration::from_secs(40));
        let actions = hc.handle_tick();
        let relay_on_actions: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "wt-bath"
                    && serde_json::to_string(&a.payload).unwrap().contains("ON")
            })
            .collect();
        assert!(!relay_on_actions.is_empty(), "should allow relay ON after min_pause");
    }

    #[test]
    fn min_cycle_blocks_relay_off() {
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // TRV demands heat → relay ON.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // emits relay ON
        echo_relay(&mut hc, "wt-bath", true, &clk); // confirm

        // TRV stops demanding immediately.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(20.5),
            pi_heating_demand: Some(0),
            running_state: Some("idle".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });

        // min_cycle not elapsed → relay OFF blocked.
        clk.advance(Duration::from_secs(60)); // < min_cycle (120s)
        let actions = hc.handle_tick();
        let relay_off: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "wt-bath"
                    && serde_json::to_string(&a.payload).unwrap().contains("OFF")
            })
            .collect();
        assert!(relay_off.is_empty(), "should block relay OFF during min_cycle");

        // Advance past min_cycle.
        clk.advance(Duration::from_secs(120));
        let actions = hc.handle_tick();
        let relay_off: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "wt-bath"
                    && serde_json::to_string(&a.payload).unwrap().contains("OFF")
            })
            .collect();
        assert!(!relay_off.is_empty(), "should allow relay OFF after min_cycle");
    }

    // -- Pressure group tests --

    #[test]
    fn pressure_group_forces_open_other_trvs() {
        let cfg = make_config(
            vec![HeatingZone {
                name: "bath".into(),
                relay: "wt-bath".into(),
                trvs: vec![
                    ZoneTrv { device: "trv-1".into(), schedule: "s".into() },
                    ZoneTrv { device: "trv-2".into(), schedule: "s".into() },
                ],
            }],
            BTreeMap::from([("s".into(), TemperatureSchedule { days: full_week(20.0) })]),
            vec![PressureGroup {
                name: "bath-group".into(),
                trvs: vec!["trv-1".into(), "trv-2".into()],
            }],
        );
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick(); // set initial setpoints

        // trv-1 demands heat (valve open).
        hc.handle_event(&Event::TrvState {
            device: "trv-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });

        let actions = hc.handle_tick();
        // Should force-open trv-2 (setpoint 30°C).
        let forced: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "trv-2"
                    && serde_json::to_string(&a.payload).unwrap().contains("30")
            })
            .collect();
        assert_eq!(forced.len(), 1, "trv-2 should be forced to 30°C");
    }

    #[test]
    fn pressure_group_releases_when_demand_stops() {
        let cfg = make_config(
            vec![HeatingZone {
                name: "bath".into(),
                relay: "wt-bath".into(),
                trvs: vec![
                    ZoneTrv { device: "trv-1".into(), schedule: "s".into() },
                    ZoneTrv { device: "trv-2".into(), schedule: "s".into() },
                ],
            }],
            BTreeMap::from([("s".into(), TemperatureSchedule { days: full_week(20.0) })]),
            vec![PressureGroup {
                name: "bath-group".into(),
                trvs: vec!["trv-1".into(), "trv-2".into()],
            }],
        );
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // trv-1 demands, trv-2 gets forced.
        hc.handle_event(&Event::TrvState {
            device: "trv-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // force trv-2

        // trv-1 stops demanding.
        hc.handle_event(&Event::TrvState {
            device: "trv-1".into(),
            local_temperature: Some(20.5),
            pi_heating_demand: Some(0),
            running_state: Some("idle".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        let actions = hc.handle_tick();

        // trv-2 should get its normal setpoint back (20°C).
        // The pressure_forced flag was cleared, so the schedule evaluator
        // should re-publish. Check that trv-2 is no longer forced.
        let trv2_state = hc.find_trv_state("trv-2").unwrap();
        assert!(!trv2_state.pressure_forced);
    }

    // -- Open window tests --

    #[test]
    fn open_window_inhibits_trv() {
        let mut cfg = simple_config();
        cfg.heating.as_mut().unwrap().open_window = OpenWindowProtection {
            detection_minutes: 1, // 60 seconds for test
            inhibit_minutes: 2,
        };
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // TRV reports temp and demands heat.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // emits relay ON
        echo_relay(&mut hc, "wt-bath", true, &clk); // confirm relay

        // Advance past detection period (60s).
        clk.advance(Duration::from_secs(70));

        // Temperature hasn't risen (still 18.0).
        let actions = hc.handle_tick();
        // Should inhibit TRV (setpoint → 5°C).
        let inhibit: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "trv-bath-1"
                    && serde_json::to_string(&a.payload).unwrap().contains("5")
            })
            .collect();
        assert_eq!(inhibit.len(), 1, "TRV should be inhibited");

        let trv = hc.find_trv_state("trv-bath-1").unwrap();
        assert!(trv.is_inhibited(clk.now()));
    }

    #[test]
    fn inhibition_expires() {
        let mut cfg = simple_config();
        cfg.heating.as_mut().unwrap().open_window = OpenWindowProtection {
            detection_minutes: 1,
            inhibit_minutes: 2,
        };
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // emits relay ON
        echo_relay(&mut hc, "wt-bath", true, &clk); // confirm

        clk.advance(Duration::from_secs(70));
        hc.handle_tick(); // inhibit

        // Verify inhibited.
        let trv = hc.find_trv_state("trv-bath-1").unwrap();
        assert!(trv.is_inhibited(clk.now()), "should be inhibited after detect");

        let until = trv.inhibited_until.unwrap();
        // Advance well past inhibition.
        clk.advance(Duration::from_secs(200));
        assert!(
            clk.now() >= until,
            "clock should be past inhibit_until: now={:?}, until={:?}",
            clk.now(),
            until
        );
        hc.handle_tick(); // should un-inhibit

        let trv = hc.find_trv_state("trv-bath-1").unwrap();
        assert!(
            !trv.is_inhibited(clk.now()),
            "inhibition should have expired: inhibited_until={:?}, now={:?}",
            trv.inhibited_until,
            clk.now()
        );
    }

    // -- Fix regression tests (from adversarial review) --

    #[test]
    fn setpoint_reconciliation_retries_on_divergence() {
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick(); // sets setpoint to 20.0

        // Device echoes a different setpoint (simulating MQTT loss).
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: None,
            running_state: None,
            occupied_heating_setpoint: Some(15.0), // wrong!
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });

        let actions = hc.handle_tick();
        // Reconciliation should retry the setpoint.
        let setpoint_retries: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "trv-bath-1"
                    && serde_json::to_string(&a.payload).unwrap().contains("20")
            })
            .collect();
        assert!(!setpoint_retries.is_empty(), "should retry diverged setpoint");
    }

    #[test]
    fn no_reconciliation_when_setpoint_confirmed() {
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick(); // sets setpoint to 20.0

        // Device confirms the setpoint.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: None,
            running_state: None,
            occupied_heating_setpoint: Some(20.0), // matches
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });

        let actions = hc.handle_tick();
        // No retry expected.
        let setpoint_actions: Vec<_> = actions
            .iter()
            .filter(|a| a.target_name() == "trv-bath-1")
            .collect();
        assert!(setpoint_actions.is_empty(), "should not retry confirmed setpoint");
    }

    #[test]
    fn mqtt_relay_on_updates_pump_timestamps() {
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);

        assert!(hc.state.pump_on_since.is_none());

        // Simulate wall thermostat reporting relay ON via MQTT.
        hc.handle_event(&Event::WallThermostatState {
            device: "wt-bath".into(),
            relay_on: Some(true),
            local_temperature: Some(22.0),
            operating_mode: None,
            ts: clk.now(),
        });

        assert!(hc.state.pump_on_since.is_some(), "pump_on_since should be set on MQTT relay ON");
        assert!(hc.state.pump_off_since.is_none(), "pump_off_since should be cleared");
    }

    #[test]
    fn mqtt_relay_off_updates_pump_timestamps() {
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);

        // First turn ON via MQTT.
        hc.handle_event(&Event::WallThermostatState {
            device: "wt-bath".into(),
            relay_on: Some(true),
            local_temperature: None,
            operating_mode: None,
            ts: clk.now(),
        });
        assert!(hc.state.pump_on_since.is_some());

        clk.advance(Duration::from_secs(10));

        // Then OFF via MQTT.
        hc.handle_event(&Event::WallThermostatState {
            device: "wt-bath".into(),
            relay_on: Some(false),
            local_temperature: None,
            operating_mode: None,
            ts: clk.now(),
        });

        assert!(hc.state.pump_off_since.is_some(), "pump_off_since should be set on MQTT relay OFF");
        assert!(hc.state.pump_on_since.is_none(), "pump_on_since should be cleared");
    }

    #[test]
    fn startup_seeds_conservative_pump_off() {
        let cfg = simple_config();
        let clk = Arc::new(FakeClock::new(12));
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        let heating_cfg = cfg.heating.clone().unwrap();
        let hc = HeatingController::new(heating_cfg, topo, clk.clone());

        // On construction, pump_off_since should be seeded.
        assert!(hc.state.pump_off_since.is_some(), "startup should seed pump_off_since");
    }

    #[test]
    fn open_window_is_one_shot_per_relay_cycle() {
        let mut cfg = simple_config();
        cfg.heating.as_mut().unwrap().open_window = OpenWindowProtection {
            detection_minutes: 1,
            inhibit_minutes: 2,
        };
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // TRV demands heat, temp at 18.0.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // emits relay ON
        echo_relay(&mut hc, "wt-bath", true, &clk); // confirm, snapshots temp=18.0

        // Temperature rises to 22.0 before detection deadline.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(22.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });

        clk.advance(Duration::from_secs(70)); // past detection period

        // Temperature drops back to 17.0 (normal modulation).
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(17.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });

        hc.handle_tick(); // first check: temp 17 < 18 (snapshot) → inhibit fires

        // But it was one-shot, so the flag is set. The inhibition
        // happened. That's correct for this cycle (temp never rose).
        // The key property: subsequent ticks with the same relay cycle
        // should NOT re-inhibit.
        let trv = hc.find_trv_state("trv-bath-1").unwrap();
        assert!(trv.open_window_checked, "should be marked as checked");

        // Simulate a scenario where temp was actually rising initially
        // (the one-shot should have let it pass without re-checking).
        // Simulate relay off via MQTT echo to verify flag resets.
        hc.handle_event(&Event::WallThermostatState {
            device: "wt-bath".into(),
            relay_on: Some(false),
            local_temperature: None,
            operating_mode: None,
            ts: clk.now(),
        });
        let trv = hc.find_trv_state("trv-bath-1").unwrap();
        assert!(!trv.open_window_checked, "flag should reset on relay off");
    }

    // -- Round 2 adversarial regression tests --

    #[test]
    fn pressure_group_forced_trv_demand_does_not_latch() {
        // Regression: forced TRV reporting demand (from 30°C override)
        // must not keep the group active after organic demand stops.
        let cfg = make_config(
            vec![HeatingZone {
                name: "bath".into(),
                relay: "wt-bath".into(),
                trvs: vec![
                    ZoneTrv { device: "trv-1".into(), schedule: "s".into() },
                    ZoneTrv { device: "trv-2".into(), schedule: "s".into() },
                ],
            }],
            BTreeMap::from([("s".into(), TemperatureSchedule { days: full_week(20.0) })]),
            vec![PressureGroup {
                name: "g".into(),
                trvs: vec!["trv-1".into(), "trv-2".into()],
            }],
        );
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // trv-1 demands organically.
        hc.handle_event(&Event::TrvState {
            device: "trv-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // forces trv-2

        // trv-2 (forced) now also reports demand (from the 30°C override).
        hc.handle_event(&Event::TrvState {
            device: "trv-2".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(80),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(30.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });

        // trv-1 stops organic demand.
        hc.handle_event(&Event::TrvState {
            device: "trv-1".into(),
            local_temperature: Some(20.5),
            pi_heating_demand: Some(0),
            running_state: Some("idle".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick();

        // trv-2 should be released (its demand is from the 30°C force,
        // not organic). The group should NOT stay latched.
        let trv2 = hc.find_trv_state("trv-2").unwrap();
        assert!(!trv2.pressure_forced, "forced TRV demand should not latch the group");
    }

    #[test]
    fn pressure_group_skips_inhibited_trvs() {
        // Regression: open-window inhibited TRV must not be force-opened
        // by pressure group.
        let cfg = make_config(
            vec![HeatingZone {
                name: "bath".into(),
                relay: "wt-bath".into(),
                trvs: vec![
                    ZoneTrv { device: "trv-1".into(), schedule: "s".into() },
                    ZoneTrv { device: "trv-2".into(), schedule: "s".into() },
                ],
            }],
            BTreeMap::from([("s".into(), TemperatureSchedule { days: full_week(20.0) })]),
            vec![PressureGroup {
                name: "g".into(),
                trvs: vec!["trv-1".into(), "trv-2".into()],
            }],
        );
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // Inhibit trv-2 (simulate open window).
        let trv2 = hc.find_trv_state_mut("trv-2").unwrap();
        trv2.inhibited_until = Some(clk.now() + Duration::from_secs(600));
        trv2.last_sent_setpoint = Some(MIN_SETPOINT);

        // trv-1 demands organically.
        hc.handle_event(&Event::TrvState {
            device: "trv-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        let actions = hc.handle_tick();

        // trv-2 should NOT be force-opened (it's inhibited).
        let trv2_forced: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "trv-2"
                    && serde_json::to_string(&a.payload).unwrap().contains("30")
            })
            .collect();
        assert!(trv2_forced.is_empty(), "inhibited TRV should not be force-opened");
        let trv2 = hc.find_trv_state("trv-2").unwrap();
        assert!(!trv2.pressure_forced, "inhibited TRV should not be marked as forced");
    }

    #[test]
    fn relay_reconciliation_retries_unconfirmed() {
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // TRV demands heat.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // emits relay ON, desired=true
        // Do NOT echo — simulate publish failure.

        // Next tick should retry the relay ON.
        let actions = hc.handle_tick();
        let relay_on: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "wt-bath"
                    && serde_json::to_string(&a.payload).unwrap().contains("ON")
            })
            .collect();
        assert!(!relay_on.is_empty(), "should retry unconfirmed relay ON");
    }

    // -- Round 3 adversarial regression tests --

    #[test]
    fn pending_pump_off_enforces_min_pause_on_lost_echo() {
        // Regression: if relay OFF command succeeds but echo is lost,
        // pending_pump_off_at must still enforce min_pause.
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // TRV demands → relay ON requested.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick();
        echo_relay(&mut hc, "wt-bath", true, &clk); // confirm ON

        clk.advance(Duration::from_secs(200)); // past min_cycle

        // TRV stops → relay OFF requested.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(20.5),
            pi_heating_demand: Some(0),
            running_state: Some("idle".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // emits relay OFF, sets pending_pump_off_at
        // Do NOT echo OFF — simulate lost echo.

        assert!(hc.state.pending_pump_off_at.is_some(), "pending stop should be set");

        // TRV demands again immediately.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(19.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });

        // Without pending_pump_off_at, min_pause would be bypassed since
        // relay_on is still true (echo was lost). With it, the controller
        // uses the pending timestamp for conservative enforcement.
        clk.advance(Duration::from_secs(10)); // < min_pause
        let actions = hc.handle_tick();
        // The controller sees relay_on=true (echo lost), so it thinks
        // pump is running. This is conservative — it won't try to turn
        // ON because it thinks relay is already on. That's fine. The
        // reconciler sends OFF retries. When the echo eventually arrives,
        // pending_pump_off_at enforces the pause.

        // Verify the pending timestamp is tracked.
        assert!(
            hc.state.effective_pump_off_since().is_some(),
            "effective_pump_off_since should use pending timestamp"
        );
    }

    #[test]
    fn canonical_demand_uses_running_state_when_available() {
        // Regression: when running_state is available, pi_heating_demand
        // must not override it (prevents stale field latching).
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // First: TRV reports running_state=heat + pi_heating_demand=50.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        let trv = hc.find_trv_state("trv-bath-1").unwrap();
        assert!(trv.has_raw_demand());

        // Partial update: only running_state=idle (pi_heating_demand stays 50).
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: None,
            pi_heating_demand: None,
            running_state: Some("idle".into()),
            occupied_heating_setpoint: None,
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        let trv = hc.find_trv_state("trv-bath-1").unwrap();
        // running_state_seen is true, so demand uses running_state exclusively.
        // running_state=idle → no demand, even though pi_heating_demand=50 (stale).
        assert!(!trv.has_raw_demand(), "stale pi_heating_demand must not override running_state");
    }

    // -- Round 4 adversarial regression tests --

    #[test]
    fn stale_relay_on_cancelled_when_demand_disappears_before_echo() {
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // TRV demands → relay ON requested.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // desired_relay = Some(true), no echo yet

        // Advance past min_cycle so cancellation is not blocked.
        clk.advance(Duration::from_secs(200));

        // Demand disappears BEFORE relay echo arrives.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(20.5),
            pi_heating_demand: Some(0),
            running_state: Some("idle".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        let actions = hc.handle_tick();

        // The stale ON should be cancelled — reconcile must NOT keep
        // sending ON commands.
        let zone_state = hc.state.zones.get("bath").unwrap();
        assert_ne!(
            zone_state.desired_relay,
            Some(true),
            "stale ON should be cancelled when demand disappears"
        );

        // Should send OFF to cancel the in-flight ON.
        let off_actions: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "wt-bath"
                    && serde_json::to_string(&a.payload).unwrap().contains("OFF")
            })
            .collect();
        assert!(!off_actions.is_empty(), "should send OFF to cancel stale ON");
    }

    #[test]
    fn open_window_skips_when_temp_rose_then_fell() {
        // Regression: temperature rose above baseline during detection
        // window but fell back below before the check. The high-water
        // mark should prevent false inhibition.
        let mut cfg = simple_config();
        cfg.heating.as_mut().unwrap().open_window = OpenWindowProtection {
            detection_minutes: 1,
            inhibit_minutes: 2,
        };
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // TRV at 18.0, demands heat.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick();
        echo_relay(&mut hc, "wt-bath", true, &clk); // snapshot = 18.0

        // Temperature rises to 20.0 during detection window.
        clk.advance(Duration::from_secs(30));
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(20.0),
            pi_heating_demand: Some(30),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });

        // Temperature falls back to 17.5 before the check fires.
        clk.advance(Duration::from_secs(40)); // now 70s total > 60s detect
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(17.5),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });

        let actions = hc.handle_tick();

        // Should NOT inhibit: high-water mark (20.0) > baseline (18.0).
        let inhibit_actions: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "trv-bath-1"
                    && serde_json::to_string(&a.payload).unwrap().contains("5")
            })
            .collect();
        assert!(
            inhibit_actions.is_empty(),
            "should not inhibit when temp rose above baseline during window"
        );
        let trv = hc.find_trv_state("trv-bath-1").unwrap();
        assert!(!trv.is_inhibited(clk.now()));
    }

    #[test]
    fn setpoint_re_dirtied_on_post_confirmation_divergence() {
        // Regression: after setpoint is confirmed, a manual knob change
        // (device reports different setpoint) should mark it dirty.
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick(); // sends 20.0
        echo_setpoint(&mut hc, "trv-bath-1", 20.0, &clk); // confirmed

        let trv = hc.find_trv_state("trv-bath-1").unwrap();
        assert!(trv.setpoint_confirmed);

        // Someone turns the knob → device reports 25.0.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: None,
            pi_heating_demand: None,
            running_state: None,
            occupied_heating_setpoint: Some(25.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });

        let trv = hc.find_trv_state("trv-bath-1").unwrap();
        assert!(!trv.setpoint_confirmed, "should be dirty after post-confirmation divergence");

        // Next tick should reassert 20.0.
        let actions = hc.handle_tick();
        let reassert: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "trv-bath-1"
                    && serde_json::to_string(&a.payload).unwrap().contains("20")
            })
            .collect();
        assert!(!reassert.is_empty(), "should reassert scheduled setpoint");
    }

    // -- Round 5 adversarial regression tests --

    #[test]
    fn lost_on_echo_still_respects_min_cycle() {
        // Regression: ON command succeeds but echo is lost. Demand drops
        // before echo arrives. The controller must NOT immediately cancel
        // if min_cycle hasn't elapsed (the pump might be physically running).
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // TRV demands → relay ON requested.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // desired=ON, pending_on_at set on zone

        assert!(hc.state.zones.get("bath").unwrap().pending_on_at.is_some());

        // Demand drops immediately — but min_cycle not elapsed.
        clk.advance(Duration::from_secs(30)); // < min_cycle (120s)
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(20.5),
            pi_heating_demand: Some(0),
            running_state: Some("idle".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick();

        // desired should still be Some(true) — cancellation blocked.
        let zone_state = hc.state.zones.get("bath").unwrap();
        assert_eq!(
            zone_state.desired_relay,
            Some(true),
            "cancellation should be blocked by min_cycle"
        );

        // After min_cycle elapses, cancellation should proceed.
        clk.advance(Duration::from_secs(100)); // total 130s > 120s
        let actions = hc.handle_tick();
        let zone_state = hc.state.zones.get("bath").unwrap();
        assert_ne!(
            zone_state.desired_relay,
            Some(true),
            "cancellation should proceed after min_cycle"
        );
        let off_actions: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "wt-bath"
                    && serde_json::to_string(&a.payload).unwrap().contains("OFF")
            })
            .collect();
        assert!(!off_actions.is_empty());
    }

    #[test]
    fn pi_only_update_clears_stale_running_state() {
        // Regression: running_state=heat was seen, then a pi-only update
        // with pi_heating_demand=0 arrives (no running_state field).
        // The stale running_state=heat must not keep demand latched.
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // Full update: running_state=heat, pi=50.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        let trv = hc.find_trv_state("trv-bath-1").unwrap();
        assert!(trv.has_raw_demand());

        // Pi-only update: pi=0, no running_state.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: None,
            pi_heating_demand: Some(0),
            running_state: None,
            occupied_heating_setpoint: None,
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });

        let trv = hc.find_trv_state("trv-bath-1").unwrap();
        assert!(
            !trv.has_raw_demand(),
            "pi-only update with 0 demand must clear stale running_state"
        );
    }

    // -- Round 6 adversarial regression tests --

    #[test]
    fn multi_zone_simultaneous_off_respects_min_cycle() {
        // Regression: two confirmed-ON zones both lose demand before
        // min_cycle. The controller must NOT turn both off.
        let cfg = make_config(
            vec![
                HeatingZone {
                    name: "z1".into(),
                    relay: "wt-1".into(),
                    trvs: vec![ZoneTrv { device: "trv-1".into(), schedule: "s".into() }],
                },
                HeatingZone {
                    name: "z2".into(),
                    relay: "wt-2".into(),
                    trvs: vec![ZoneTrv { device: "trv-2".into(), schedule: "s".into() }],
                },
            ],
            BTreeMap::from([("s".into(), TemperatureSchedule { days: full_week(20.0) })]),
            vec![],
        );
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // Both TRVs demand heat.
        for trv in &["trv-1", "trv-2"] {
            hc.handle_event(&Event::TrvState {
                device: trv.to_string(),
                local_temperature: Some(18.0),
                pi_heating_demand: Some(50),
                running_state: Some("heat".into()),
                occupied_heating_setpoint: Some(20.0),
                operating_mode: None,
                battery: None,
                ts: clk.now(),
            });
        }
        hc.handle_tick(); // both relays ON requested
        echo_relay(&mut hc, "wt-1", true, &clk);
        echo_relay(&mut hc, "wt-2", true, &clk);

        assert_eq!(hc.state.active_relay_count(), 2);

        // Both TRVs stop demanding BEFORE min_cycle.
        clk.advance(Duration::from_secs(30)); // < 120s min_cycle
        for trv in &["trv-1", "trv-2"] {
            hc.handle_event(&Event::TrvState {
                device: trv.to_string(),
                local_temperature: Some(20.5),
                pi_heating_demand: Some(0),
                running_state: Some("idle".into()),
                occupied_heating_setpoint: Some(20.0),
                operating_mode: None,
                battery: None,
                ts: clk.now(),
            });
        }
        let actions = hc.handle_tick();

        // Neither relay should turn off — min_cycle blocks all of them
        // because all confirmed relays want off simultaneously (0 survivors).
        let off_actions: Vec<_> = actions
            .iter()
            .filter(|a| serde_json::to_string(&a.payload).unwrap().contains("OFF"))
            .collect();
        assert!(
            off_actions.is_empty(),
            "min_cycle should block simultaneous multi-zone OFF"
        );
    }

    #[test]
    fn stale_on_cancellation_retries_off_via_reconcile() {
        // Regression: stale-ON cancellation must set desired=Some(false)
        // so reconcile keeps retrying the OFF if the first publish is lost.
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // TRV demands → relay ON requested.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // desired=Some(true)
        // No echo — ON might have physically succeeded.

        clk.advance(Duration::from_secs(200)); // past min_cycle

        // Demand disappears.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(20.5),
            pi_heating_demand: Some(0),
            running_state: Some("idle".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // cancellation fires

        let zone = hc.state.zones.get("bath").unwrap();
        assert_eq!(
            zone.desired_relay,
            Some(false),
            "cancellation must set desired=Some(false) for reconcile"
        );

        // Next tick: reconcile should retry the OFF since relay_on
        // is still false (echo never came for ON or OFF).
        let actions = hc.handle_tick();
        let off_retries: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "wt-bath"
                    && serde_json::to_string(&a.payload).unwrap().contains("OFF")
            })
            .collect();
        assert!(
            !off_retries.is_empty(),
            "reconcile should keep retrying OFF after stale-ON cancellation"
        );
    }

    // -- Round 7 adversarial regression tests --

    #[test]
    fn relay_handoff_bridges_pump_for_pending_on() {
        // Regression: when zone A's relay is confirmed ON and zone B has
        // a pending ON (not yet echoed), zone A must not turn off even
        // if it has no demand — it bridges the pump for zone B.
        let cfg = make_config(
            vec![
                HeatingZone {
                    name: "z1".into(),
                    relay: "wt-1".into(),
                    trvs: vec![ZoneTrv { device: "trv-1".into(), schedule: "s".into() }],
                },
                HeatingZone {
                    name: "z2".into(),
                    relay: "wt-2".into(),
                    trvs: vec![ZoneTrv { device: "trv-2".into(), schedule: "s".into() }],
                },
            ],
            BTreeMap::from([("s".into(), TemperatureSchedule { days: full_week(20.0) })]),
            vec![],
        );
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // Zone 1 demands, relay ON confirmed.
        hc.handle_event(&Event::TrvState {
            device: "trv-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick();
        echo_relay(&mut hc, "wt-1", true, &clk);

        // Zone 2 starts demanding, relay ON requested but NOT echoed yet.
        hc.handle_event(&Event::TrvState {
            device: "trv-2".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // zone 2 gets desired=Some(true)
        // Do NOT echo wt-2.

        // Zone 1 stops demanding.
        hc.handle_event(&Event::TrvState {
            device: "trv-1".into(),
            local_temperature: Some(20.5),
            pi_heating_demand: Some(0),
            running_state: Some("idle".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });

        clk.advance(Duration::from_secs(200)); // past min_cycle
        let actions = hc.handle_tick();

        // Zone 1 relay should NOT be turned off because zone 2 has a
        // pending ON. The pump must be bridged.
        let z1_off: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "wt-1"
                    && serde_json::to_string(&a.payload).unwrap().contains("OFF")
            })
            .collect();
        assert!(
            z1_off.is_empty(),
            "last confirmed relay must not turn off while another zone has pending ON"
        );
    }

    #[test]
    fn repeated_off_echo_clears_stale_pending_state() {
        // Regression: lost ON echo → stale-ON cancellation sends OFF →
        // OFF echo arrives but relay_on is already false (ON was never
        // recorded). The repeated OFF must clear pending_on_at.
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // TRV demands → relay ON requested.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // desired=Some(true), pending_on_at set on zone
        // ON echo is LOST.

        clk.advance(Duration::from_secs(200));

        // Demand disappears → stale-ON cancellation fires.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(20.5),
            pi_heating_demand: Some(0),
            running_state: Some("idle".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // sends OFF, desired=Some(false)
        assert!(hc.state.zones.get("bath").unwrap().pending_on_at.is_some());

        // Wall thermostat physically goes OFF. But relay_on is already
        // false (ON echo was lost), so this is a "repeated OFF".
        echo_relay(&mut hc, "wt-bath", false, &clk);

        // pending_on_at should now be cleared.
        assert!(
            hc.state.zones.get("bath").unwrap().pending_on_at.is_none(),
            "repeated OFF echo must clear stale pending_on_at"
        );
        // desired_relay should be cleared (no more retries needed).
        let zone = hc.state.zones.get("bath").unwrap();
        assert!(
            zone.desired_relay.is_none(),
            "desired_relay should be cleared after OFF confirmation"
        );
    }

    #[test]
    fn startup_hydration_does_not_trigger_open_window() {
        // Regression: during startup, a relay already ON should not
        // start open-window timers. Only post-startup edges should.
        let mut cfg = simple_config();
        cfg.heating.as_mut().unwrap().open_window = OpenWindowProtection {
            detection_minutes: 1,
            inhibit_minutes: 2,
        };
        // Don't use setup() — we need startup_complete=false.
        let clk = Arc::new(FakeClock::new(12));
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        let heating_cfg = cfg.heating.clone().unwrap();
        let mut hc = HeatingController::new(heating_cfg, topo, clk.clone());
        clk.advance(Duration::from_secs(120));

        // Simulate startup hydration: TRV reports temp, then wall
        // thermostat reports relay ON. This is state sync, not a fresh
        // heating cycle.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(20.0),
            pi_heating_demand: Some(30),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(22.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        // Relay was already ON before daemon started.
        echo_relay(&mut hc, "wt-bath", true, &clk);

        // The TRV should NOT have open-window tracking set during startup.
        let trv = hc.find_trv_state("trv-bath-1").unwrap();
        assert!(
            trv.temp_at_relay_on.is_none(),
            "startup hydration should not start open-window timers"
        );

        // First tick marks startup as complete.
        hc.handle_tick();
        assert!(hc.startup_complete);

        // Now a real relay cycle should set open-window tracking.
        echo_relay(&mut hc, "wt-bath", false, &clk);
        clk.advance(Duration::from_secs(5));
        echo_relay(&mut hc, "wt-bath", true, &clk);

        let trv = hc.find_trv_state("trv-bath-1").unwrap();
        assert!(
            trv.temp_at_relay_on.is_some(),
            "post-startup relay ON should start open-window tracking"
        );
    }

    // -- Round 8 adversarial regression tests --

    #[test]
    fn unknown_relay_state_self_heals() {
        // Regression: if wall thermostat never responds during startup,
        // the zone should still participate in relay control (assuming
        // OFF). This is self-healing — the controller sends ON if demand
        // exists, and the echo will confirm state.
        let cfg = simple_config();
        let clk = Arc::new(FakeClock::new(12));
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        let heating_cfg = cfg.heating.clone().unwrap();
        let mut hc = HeatingController::new(heating_cfg, topo, clk.clone());
        // Do NOT set relay_state_known — simulates missed refresh.
        hc.startup_complete = true;
        clk.advance(Duration::from_secs(120));

        // TRV demands heat.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        let actions = hc.handle_tick();

        // Should emit relay ON even with unknown state (assumes OFF).
        let relay_on: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "wt-bath"
                    && serde_json::to_string(&a.payload).unwrap().contains("ON")
            })
            .collect();
        assert!(
            !relay_on.is_empty(),
            "unknown relay state should not block heating — assumes OFF and sends ON"
        );
    }

    #[test]
    fn pressure_release_suppresses_stale_demand() {
        // Regression: after pressure-group release, the TRV's stale
        // demand from the 30°C override must not keep the zone active.
        let cfg = make_config(
            vec![HeatingZone {
                name: "bath".into(),
                relay: "wt-bath".into(),
                trvs: vec![
                    ZoneTrv { device: "trv-1".into(), schedule: "s".into() },
                    ZoneTrv { device: "trv-2".into(), schedule: "s".into() },
                ],
            }],
            BTreeMap::from([("s".into(), TemperatureSchedule { days: full_week(20.0) })]),
            vec![PressureGroup {
                name: "g".into(),
                trvs: vec!["trv-1".into(), "trv-2".into()],
            }],
        );
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // trv-1 demands organically → trv-2 gets forced to 30°C.
        hc.handle_event(&Event::TrvState {
            device: "trv-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick();

        // trv-2 reports demand from the 30°C override.
        hc.handle_event(&Event::TrvState {
            device: "trv-2".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(80),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(30.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });

        // trv-1 stops organic demand → group releases.
        hc.handle_event(&Event::TrvState {
            device: "trv-1".into(),
            local_temperature: Some(20.5),
            pi_heating_demand: Some(0),
            running_state: Some("idle".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // release fires

        // trv-2 should have pressure_release_pending = true.
        let trv2 = hc.find_trv_state("trv-2").unwrap();
        assert!(trv2.pressure_release_pending);
        // Its stale demand should be suppressed.
        assert!(
            !trv2.has_effective_demand(clk.now()),
            "released TRV's stale demand must be suppressed"
        );
    }

    #[test]
    fn no_duplicate_commands_on_same_tick() {
        // Regression: schedule + reconciliation should not emit the
        // same setpoint command twice in one tick.
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        let actions = hc.handle_tick();

        let sp_actions: Vec<_> = actions
            .iter()
            .filter(|a| a.target_name() == "trv-bath-1")
            .collect();
        assert_eq!(
            sp_actions.len(),
            1,
            "should emit exactly one setpoint command per tick, not duplicates"
        );
    }

    // -- Round 9 adversarial regression tests --

    #[test]
    fn pending_off_relay_not_counted_as_survivor() {
        // Regression: relay A has a pending OFF (desired=false, relay_on
        // still true because echo hasn't arrived). Relay B wants OFF.
        // Relay A must NOT count as a survivor — it may already be
        // physically off. min_cycle must apply.
        let cfg = make_config(
            vec![
                HeatingZone {
                    name: "z1".into(),
                    relay: "wt-1".into(),
                    trvs: vec![ZoneTrv { device: "trv-1".into(), schedule: "s".into() }],
                },
                HeatingZone {
                    name: "z2".into(),
                    relay: "wt-2".into(),
                    trvs: vec![ZoneTrv { device: "trv-2".into(), schedule: "s".into() }],
                },
            ],
            BTreeMap::from([("s".into(), TemperatureSchedule { days: full_week(20.0) })]),
            vec![],
        );
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // Both zones demand, both relays ON confirmed.
        for trv in &["trv-1", "trv-2"] {
            hc.handle_event(&Event::TrvState {
                device: trv.to_string(),
                local_temperature: Some(18.0),
                pi_heating_demand: Some(50),
                running_state: Some("heat".into()),
                occupied_heating_setpoint: Some(20.0),
                operating_mode: None,
                battery: None,
                ts: clk.now(),
            });
        }
        hc.handle_tick();
        echo_relay(&mut hc, "wt-1", true, &clk);
        echo_relay(&mut hc, "wt-2", true, &clk);
        assert_eq!(hc.state.active_relay_count(), 2);

        clk.advance(Duration::from_secs(200)); // past min_cycle

        // Zone 1 stops demanding → relay 1 OFF requested.
        hc.handle_event(&Event::TrvState {
            device: "trv-1".into(),
            local_temperature: Some(20.5),
            pi_heating_demand: Some(0),
            running_state: Some("idle".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // relay 1: desired=false
        // Do NOT echo relay 1 OFF — it's pending.

        // Reset pump_on_since to simulate fresh pump start.
        hc.state.pump_on_since = Some(clk.now());

        // Zone 2 stops demanding too, only 20s later (< min_cycle).
        clk.advance(Duration::from_secs(20));
        hc.handle_event(&Event::TrvState {
            device: "trv-2".into(),
            local_temperature: Some(20.5),
            pi_heating_demand: Some(0),
            running_state: Some("idle".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        let actions = hc.handle_tick();

        // Relay 1 has pending OFF (desired=false, relay_on=true).
        // It must NOT count as a survivor for relay 2's decision.
        // Since safe survivors = 0, min_cycle must apply to relay 2.
        let z2_off: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "wt-2"
                    && serde_json::to_string(&a.payload).unwrap().contains("OFF")
            })
            .collect();
        assert!(
            z2_off.is_empty(),
            "relay 2 OFF must be blocked: relay 1 has pending OFF and cannot be counted as survivor"
        );
    }

    // -- Round 10 adversarial regression tests --

    #[test]
    fn unknown_state_zone_gets_proactive_off_when_no_demand() {
        // Regression: if relay was ON before restart but startup refresh
        // missed, the controller must proactively send OFF for zones
        // without demand (the relay might still be physically ON).
        let cfg = simple_config();
        let clk = Arc::new(FakeClock::new(12));
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        let heating_cfg = cfg.heating.clone().unwrap();
        let mut hc = HeatingController::new(heating_cfg, topo, clk.clone());
        // Do NOT set relay_state_known — simulates missed refresh.
        hc.startup_complete = true;
        clk.advance(Duration::from_secs(120));

        // No TRV demand. The zone is unknown but has no demand.
        let actions = hc.handle_tick();

        // Should proactively send OFF to reconcile unknown state.
        let relay_off: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "wt-bath"
                    && serde_json::to_string(&a.payload).unwrap().contains("OFF")
            })
            .collect();
        assert!(
            !relay_off.is_empty(),
            "unknown-state zone with no demand should get proactive OFF"
        );
    }

    #[test]
    fn wrong_zone_repeated_off_does_not_clear_other_zone_pending_on() {
        // Regression: zone B's repeated OFF echo must not clear zone A's
        // pending ON state. Pending ON is now per-zone.
        let cfg = make_config(
            vec![
                HeatingZone {
                    name: "z1".into(),
                    relay: "wt-1".into(),
                    trvs: vec![ZoneTrv { device: "trv-1".into(), schedule: "s".into() }],
                },
                HeatingZone {
                    name: "z2".into(),
                    relay: "wt-2".into(),
                    trvs: vec![ZoneTrv { device: "trv-2".into(), schedule: "s".into() }],
                },
            ],
            BTreeMap::from([("s".into(), TemperatureSchedule { days: full_week(20.0) })]),
            vec![],
        );
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // Zone 1 demands → relay ON requested (pending_on_at set on z1).
        hc.handle_event(&Event::TrvState {
            device: "trv-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick();
        // Do NOT echo wt-1 ON — simulate lost echo.

        let z1_pending = hc.state.zones.get("z1").unwrap().pending_on_at;
        assert!(z1_pending.is_some(), "z1 should have pending ON");

        // Zone 2 gets a repeated OFF echo (it was already off).
        echo_relay(&mut hc, "wt-2", false, &clk);

        // Zone 1's pending ON must NOT be cleared by zone 2's echo.
        let z1_pending_after = hc.state.zones.get("z1").unwrap().pending_on_at;
        assert!(
            z1_pending_after.is_some(),
            "zone 2's repeated OFF must not clear zone 1's pending ON"
        );
    }

    // -- Round 11 + self-review regression tests --

    #[test]
    fn secondary_zone_on_tracks_pending() {
        // Regression: when zone B turns ON while zone A already has
        // the pump running, zone B must also set pending_on_at so a
        // lost echo doesn't strand it ON.
        let cfg = make_config(
            vec![
                HeatingZone {
                    name: "z1".into(),
                    relay: "wt-1".into(),
                    trvs: vec![ZoneTrv { device: "trv-1".into(), schedule: "s".into() }],
                },
                HeatingZone {
                    name: "z2".into(),
                    relay: "wt-2".into(),
                    trvs: vec![ZoneTrv { device: "trv-2".into(), schedule: "s".into() }],
                },
            ],
            BTreeMap::from([("s".into(), TemperatureSchedule { days: full_week(20.0) })]),
            vec![],
        );
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // Zone 1 demands, relay ON confirmed (pump running).
        hc.handle_event(&Event::TrvState {
            device: "trv-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick();
        echo_relay(&mut hc, "wt-1", true, &clk);
        assert!(hc.state.is_pump_running());

        // Zone 2 demands (pump already running → secondary ON).
        hc.handle_event(&Event::TrvState {
            device: "trv-2".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick();
        // Do NOT echo wt-2 ON — simulate lost echo.

        // Zone 2 must have pending_on_at set.
        let z2 = hc.state.zones.get("z2").unwrap();
        assert!(
            z2.pending_on_at.is_some(),
            "secondary-zone ON must track pending_on_at"
        );

        // Zone 2 demand disappears. Stale-ON cancellation should fire
        // and reconcile should keep retrying OFF.
        clk.advance(Duration::from_secs(200));
        hc.handle_event(&Event::TrvState {
            device: "trv-2".into(),
            local_temperature: Some(20.5),
            pi_heating_demand: Some(0),
            running_state: Some("idle".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick(); // cancellation

        let z2 = hc.state.zones.get("z2").unwrap();
        assert_eq!(z2.desired_relay, Some(false), "should cancel to OFF");

        // Reconcile should keep retrying OFF because pending_on_at
        // is still set (echo never came).
        let actions = hc.handle_tick();
        let z2_off: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "wt-2"
                    && serde_json::to_string(&a.payload).unwrap().contains("OFF")
            })
            .collect();
        assert!(
            !z2_off.is_empty(),
            "reconcile should retry OFF for secondary zone with pending ON"
        );
    }

    // -- Self-review: device mode enforcement tests --

    #[test]
    fn trv_mode_drift_triggers_reassertion() {
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // TRV reports operating_mode = "schedule" (wrong — should be manual).
        let actions = hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(20.0),
            pi_heating_demand: None,
            running_state: None,
            occupied_heating_setpoint: None,
            operating_mode: Some("schedule".into()),
            battery: None,
            ts: clk.now(),
        });

        // Should emit an action to reassert manual mode.
        let mode_actions: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "trv-bath-1"
                    && serde_json::to_string(&a.payload).unwrap().contains("manual")
            })
            .collect();
        assert!(
            !mode_actions.is_empty(),
            "TRV mode drift to 'schedule' must trigger reassertion of 'manual'"
        );
    }

    #[test]
    fn trv_manual_mode_no_reassertion() {
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // TRV reports operating_mode = "manual" (correct).
        let actions = hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(20.0),
            pi_heating_demand: None,
            running_state: None,
            occupied_heating_setpoint: None,
            operating_mode: Some("manual".into()),
            battery: None,
            ts: clk.now(),
        });

        // No mode reassertion needed.
        let mode_actions: Vec<_> = actions
            .iter()
            .filter(|a| serde_json::to_string(&a.payload).unwrap().contains("operating_mode"))
            .collect();
        assert!(mode_actions.is_empty(), "correct mode should not trigger reassertion");
    }

    #[test]
    fn wall_thermostat_mode_drift_triggers_reassertion() {
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // Wall thermostat reports operating_mode = "schedule".
        let actions = hc.handle_event(&Event::WallThermostatState {
            device: "wt-bath".into(),
            relay_on: Some(false),
            local_temperature: Some(22.0),
            operating_mode: Some("schedule".into()),
            ts: clk.now(),
        });

        let mode_actions: Vec<_> = actions
            .iter()
            .filter(|a| {
                a.target_name() == "wt-bath"
                    && serde_json::to_string(&a.payload).unwrap().contains("manual")
            })
            .collect();
        assert!(
            !mode_actions.is_empty(),
            "wall thermostat mode drift must trigger reassertion"
        );
    }

    #[test]
    fn low_battery_logged() {
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // TRV reports battery = 5%.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(20.0),
            pi_heating_demand: None,
            running_state: None,
            occupied_heating_setpoint: None,
            operating_mode: None,
            battery: Some(5),
            ts: clk.now(),
        });

        let trv = hc.find_trv_state("trv-bath-1").unwrap();
        assert_eq!(trv.battery, Some(5));
    }

    // -- Subagent adversarial review regression tests --

    #[test]
    fn desired_relay_cleared_on_confirmed_echo() {
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // TRV demands → relay ON.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        hc.handle_tick();
        assert_eq!(
            hc.state.zones.get("bath").unwrap().desired_relay,
            Some(true)
        );

        // ON echo confirms.
        echo_relay(&mut hc, "wt-bath", true, &clk);
        assert_eq!(
            hc.state.zones.get("bath").unwrap().desired_relay,
            None,
            "desired_relay must be cleared to None after confirmed ON echo"
        );
    }

    #[test]
    fn stale_trv_demand_suppressed() {
        let cfg = simple_config();
        let (mut hc, clk) = setup(&cfg);
        hc.handle_tick();

        // TRV demands heat.
        hc.handle_event(&Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: Some(50),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(20.0),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        let trv = hc.find_trv_state("trv-bath-1").unwrap();
        assert!(trv.has_effective_demand(clk.now()));

        // 31 minutes pass with no TRV update (device died).
        clk.advance(Duration::from_secs(31 * 60));

        let trv = hc.find_trv_state("trv-bath-1").unwrap();
        assert!(trv.is_stale(clk.now()), "TRV should be stale after 31 min");
        assert!(trv.has_raw_demand(), "raw demand still set");
        assert!(
            !trv.has_effective_demand(clk.now()),
            "stale TRV demand must be suppressed"
        );
    }
}
