//! Heating logic operating directly on TASS entities.
//!
//! Implements schedule evaluation, relay control with global short-cycling
//! protection, pressure group enforcement, open window detection, setpoint
//! and relay reconciliation, HA discovery/state publishing, and device
//! mode enforcement.
//!
//! All state lives in [`WorldState`]'s `heating_zones` and `trvs` maps
//! plus a few pump-tracking fields on [`EventProcessor`].

use std::time::{Duration, Instant};

use crate::config::heating::Weekday;
use crate::domain::action::{Action, Payload};
use crate::domain::event::Event;
use crate::domain::ha_discovery;
use crate::entities::trv::HeatingRunningState;
use crate::entities::heating_zone::{HeatingZoneActual, HeatingZoneTarget};
use crate::entities::trv::{ForceOpenReason, TrvActual, TrvTarget};
use crate::tass::{Owner, TargetPhase};

use super::EventProcessor;

const MIN_SETPOINT: f64 = 5.0;
const MAX_SETPOINT: f64 = 30.0;

/// Wall thermostat state refresh interval.
const WT_REFRESH_INTERVAL: Duration = Duration::from_secs(5 * 60);

impl EventProcessor {
    // ---- Event dispatch -------------------------------------------------------

    pub(super) fn handle_heating_event(&mut self, event: &Event) -> Vec<Action> {
        match event {
            Event::TrvState {
                device,
                local_temperature,
                pi_heating_demand,
                running_state,
                occupied_heating_setpoint,
                operating_mode,
                battery,
                ts,
            } => {
                self.handle_trv_state(
                    device,
                    *local_temperature,
                    *pi_heating_demand,
                    running_state.as_deref(),
                    *occupied_heating_setpoint,
                    operating_mode.as_deref(),
                    *battery,
                    *ts,
                );
                self.check_trv_mode(device)
            }
            Event::WallThermostatState {
                device,
                relay_on,
                local_temperature,
                operating_mode,
                ts,
            } => {
                self.handle_wall_thermostat_state(
                    device, *relay_on, *local_temperature,
                    operating_mode.as_deref(), *ts,
                );
                self.check_wt_mode(device)
            }
            _ => Vec::new(),
        }
    }

    // ---- TRV state update -----------------------------------------------------

    fn handle_trv_state(
        &mut self,
        device: &str,
        local_temperature: Option<f64>,
        pi_heating_demand: Option<u8>,
        running_state: Option<&str>,
        occupied_heating_setpoint: Option<f64>,
        operating_mode: Option<&str>,
        battery: Option<u8>,
        _ts: Instant,
    ) {
        let now = self.clock.now();
        // Find the TRV — only process TRVs that belong to a heating zone.
        let heating_config = match &self.heating_config {
            Some(c) => c,
            None => return,
        };
        let is_known_trv = heating_config.zones.iter()
            .any(|z| z.trvs.iter().any(|zt| zt.device == device));
        if !is_known_trv {
            return;
        }

        let trv = self.world.trv(device);
        trv.last_seen = Some(now);

        // Build updated actual state, merging with existing.
        let prev = trv.actual.value().cloned().unwrap_or_default();
        let new_temp = local_temperature.or(prev.local_temperature);
        let new_demand = pi_heating_demand.or(prev.pi_heating_demand);

        let mut new_rs = prev.running_state;
        let mut new_rs_seen = prev.running_state_seen;
        if let Some(rs) = running_state {
            if let Some(parsed) = HeatingRunningState::parse(rs) {
                new_rs = parsed;
                new_rs_seen = true;
            }
        }
        // If pi-only update (no running_state in this message) and we
        // previously trusted running_state, sync from pi to avoid stale
        // demand latching.
        if running_state.is_none() && new_rs_seen {
            if let Some(demand) = pi_heating_demand {
                new_rs = if demand > 0 {
                    HeatingRunningState::Heat
                } else {
                    HeatingRunningState::Idle
                };
            }
        }

        let actual = TrvActual {
            local_temperature: new_temp,
            pi_heating_demand: new_demand,
            running_state: new_rs,
            running_state_seen: new_rs_seen,
            setpoint: occupied_heating_setpoint.or(prev.setpoint),
            operating_mode: operating_mode.map(String::from).or(prev.operating_mode),
            battery: battery.or(prev.battery),
        };
        trv.actual.update(actual, now);

        // Temperature handling for open window detection.
        if let Some(temp) = local_temperature {
            trv.last_temp_at = Some(now);
            // Only track baseline/high-water while a detection cycle is
            // active (relay-ON). Backfill the baseline if relay-ON found us
            // without a fresh temperature reading.
            if trv.open_window.baseline_established_at.is_some() {
                if trv.open_window.temp_at_relay_on.is_none() {
                    trv.open_window.temp_at_relay_on = Some(temp);
                }
                trv.open_window.temp_high_water = Some(
                    trv.open_window.temp_high_water.map_or(temp, |hw| hw.max(temp)),
                );
            }
        }

        // Check setpoint confirmation.
        if let Some(sp) = occupied_heating_setpoint {
            if let Some(target) = trv.target.value() {
                let is_normal_setpoint = matches!(target, TrvTarget::Setpoint(_));
                let target_sp = match target {
                    TrvTarget::Setpoint(t) => Some(*t),
                    TrvTarget::Inhibited { .. } => Some(MIN_SETPOINT),
                    TrvTarget::ForcedOpen { .. } => Some(MAX_SETPOINT),
                };
                if let Some(target_val) = target_sp {
                    if (target_val - sp).abs() < 0.1 {
                        if trv.target.phase() == TargetPhase::Commanded
                            || trv.target.phase() == TargetPhase::Stale
                        {
                            trv.target.confirm(now);
                            // Clear force reason once a non-forced setpoint is confirmed.
                            if is_normal_setpoint {
                                trv.last_force_reason = None;
                            }
                        }
                    } else if trv.target.phase() == TargetPhase::Confirmed {
                        // Post-confirmation divergence: device moved away
                        // (manual knob change, device reset). Re-dirty.
                        trv.target.set_and_command(
                            trv.target.value().unwrap().clone(),
                            trv.target.owner().unwrap_or(Owner::Schedule),
                            now,
                        );
                        trv.setpoint_dirty_gen = self.heating_tick_gen;
                        tracing::info!(
                            trv = %device,
                            target = target_val, reported = sp,
                            "setpoint diverged after confirmation, marking dirty"
                        );
                    }
                }
            }
        }

        if let Some(batt) = battery {
            if batt <= 10 {
                tracing::warn!(trv = %device, battery = batt, "TRV battery critically low");
            }
        }
    }

    // ---- Wall thermostat state update -----------------------------------------

    fn handle_wall_thermostat_state(
        &mut self,
        device: &str,
        relay_on: Option<bool>,
        local_temperature: Option<f64>,
        operating_mode: Option<&str>,
        _ts: Instant,
    ) {
        let now = self.clock.now();
        let heating_config = match &self.heating_config {
            Some(c) => c.clone(),
            None => return,
        };

        // Find zone for this relay.
        let zone_cfg = heating_config.zones.iter()
            .find(|z| z.relay == device);
        let Some(zone_cfg) = zone_cfg else { return };
        let zone_name = zone_cfg.name.clone();
        let trv_devices: Vec<String> = zone_cfg.trvs.iter()
            .map(|zt| zt.device.clone())
            .collect();

        let zone = self.world.heating_zone(&zone_name);
        zone.wt_last_seen = Some(now);

        if let Some(mode) = operating_mode {
            zone.wt_operating_mode = Some(mode.to_string());
        }

        let Some(on) = relay_on else { return };

        // Snapshot before mutation for pump tracking.
        let relays_on_before = self.active_relay_count();
        let pump_running = self.is_pump_running();

        let zone = self.world.heating_zone(&zone_name);
        let first_contact = !zone.relay_state_known;
        zone.relay_state_known = true;
        let was_on = zone.is_relay_on();

        if was_on == on {
            // First contact with relay OFF: seed pump_off_since.
            if first_contact && !on && !pump_running {
                self.pump_off_since = self.pump_off_since.or(Some(now));
                tracing::info!(
                    zone = %zone_name, relay = device,
                    "first contact: relay confirmed OFF, seeding pump_off_since"
                );
            }
            // Repeated OFF echo: if we just sent an ON command, ignore
            // this stale/reordered echo — the relay hasn't switched yet.
            let zone = self.world.heating_zone(&zone_name);
            if !on && zone.target.phase() == TargetPhase::Commanded {
                if let Some(HeatingZoneTarget::Heating) = zone.target.value() {
                    // Only ignore OFF echoes within a bounded grace period after the
                    // ON command was issued. Beyond this window, accept the OFF as
                    // evidence the ON command failed (rejected / lost by MQTT).
                    const RELAY_ACTUATION_GRACE: Duration = Duration::from_secs(15);
                    let within_grace = zone.target.since()
                        .is_some_and(|since| now.duration_since(since) < RELAY_ACTUATION_GRACE);
                    if within_grace {
                        tracing::info!(
                            zone = %zone_name, relay = device,
                            "ignoring OFF echo within relay actuation grace period (ON in-flight)"
                        );
                    } else {
                        tracing::warn!(
                            zone = %zone_name, relay = device,
                            "OFF echo after grace period — ON command likely failed; accepting OFF"
                        );
                        // Accept the OFF: update actual state, reset target, track pump.
                        zone.actual.update(HeatingZoneActual { relay_on: false, temperature: local_temperature }, now);
                        zone.target.set_and_command(HeatingZoneTarget::Off, Owner::Schedule, now);
                        zone.target.confirm(now);
                        zone.relay_on_since = None;
                        if relays_on_before == 0 {
                            self.pump_off_since = Some(now);
                            self.pump_on_since = None;
                        }
                    }
                } else if let Some(HeatingZoneTarget::Off) = zone.target.value() {
                    // Pending OFF confirmed by repeated echo.
                    zone.target.confirm(now);
                    self.pump_off_since = Some(now);
                    tracing::info!(
                        zone = %zone_name, relay = device,
                        "MQTT: repeated OFF echo confirms relay off, recording pump stop"
                    );
                }
            }
            return;
        }

        // State transition.
        let zone = self.world.heating_zone(&zone_name);
        zone.actual.update(HeatingZoneActual { relay_on: on, temperature: local_temperature }, now);

        if on {
            // OFF -> ON edge.
            zone.relay_on_since = Some(now);
            if self.startup_complete {
                for trv_dev in &trv_devices {
                    let trv = self.world.trv(trv_dev);
                    // Use the last known temperature as the baseline, provided
                    // it is fresh. The detection clock always starts at the
                    // relay-ON moment, independent of when the reading was
                    // physically taken. If no fresh temperature is available
                    // the baseline is backfilled by the next arriving sample.
                    let baseline = if trv.has_fresh_temp(now) {
                        trv.actual.value().and_then(|a| a.local_temperature)
                    } else {
                        None
                    };
                    trv.open_window.start_detection(now, baseline);
                }
            }
            // Confirm the target ON.
            let zone = self.world.heating_zone(&zone_name);
            if zone.target.value() == Some(&HeatingZoneTarget::Heating)
                && zone.target.is_actionable()
            {
                zone.target.confirm(now);
            }
            // Pump tracking.
            if relays_on_before == 0 {
                self.pump_on_since = Some(now);
                self.pump_off_since = None;
                tracing::info!(
                    zone = %zone_name, relay = device,
                    "MQTT: relay ON observed, pump starting"
                );
            }
        } else {
            // ON -> OFF edge.
            let zone = self.world.heating_zone(&zone_name);
            zone.relay_on_since = None;
            // Release min_cycle-forced TRVs for this zone.
            for trv_dev in &trv_devices {
                let trv = self.world.trv(trv_dev);
                trv.open_window.reset();
                if trv.target.value().is_some_and(|t| matches!(t, TrvTarget::ForcedOpen { reason: ForceOpenReason::MinCycle })) {
                    // Release: set to placeholder Commanded so the schedule
                    // evaluator overwrites with the real setpoint on the
                    // next tick. last_force_reason is cleared when that
                    // real setpoint is confirmed.
                    trv.target.set_and_command(TrvTarget::Setpoint(0.0), Owner::Schedule, now);
                    tracing::info!(
                        zone = %zone_name, relay = device,
                        "min_cycle hold: releasing forced TRV (relay OFF confirmed)"
                    );
                }
            }
            // Confirm the target OFF.
            let zone = self.world.heating_zone(&zone_name);
            if zone.target.value() == Some(&HeatingZoneTarget::Off)
                && zone.target.is_actionable()
            {
                zone.target.confirm(now);
            }
            // Pump tracking.
            if relays_on_before == 1 {
                self.pump_off_since = Some(now);
                self.pump_on_since = None;
                tracing::info!(
                    zone = %zone_name, relay = device,
                    "MQTT: relay OFF observed, pump stopping"
                );
            }
        }

        // After updating actual state, check for target/actual mismatch.
        // If target is Confirmed but actual diverges (e.g., manual intervention
        // or late echo), re-dirty the target so reconcile retries.
        let zone = self.world.heating_zone(&zone_name);
        if zone.target.phase() == TargetPhase::Confirmed {
            let mismatch = match zone.target.value() {
                Some(&HeatingZoneTarget::Off) => zone.is_relay_on(),
                Some(&HeatingZoneTarget::Heating) => !zone.is_relay_on(),
                None => false,
            };
            if mismatch {
                let target_value = zone.target.value().unwrap().clone();
                let owner = zone.target.owner().unwrap();
                tracing::warn!(
                    zone = zone_name.as_str(),
                    target = ?target_value,
                    relay_on = zone.is_relay_on(),
                    "relay/target mismatch detected — re-dirtying target for reconciliation"
                );
                zone.target.set_and_command(target_value, owner, now);
            }
        }
    }

    // ---- Tick handler ---------------------------------------------------------

    pub(super) fn handle_heating_tick(&mut self) -> Vec<Action> {
        self.heating_tick_gen += 1;
        let mut actions = Vec::new();

        let heating_config = match &self.heating_config {
            Some(c) => c.clone(),
            None => return actions,
        };

        if !self.startup_complete {
            self.startup_complete = true;
            for zone in &heating_config.zones {
                actions.push(Action::get_device_state(
                    zone.relay.clone(),
                    Payload::GetState { state: "" },
                ));
                tracing::info!(
                    zone = %zone.name,
                    relay = %zone.relay,
                    "startup: requesting wall thermostat state via GET"
                );
            }
        }

        let now = self.clock.now();
        let weekday = self.clock.local_weekday();
        let hour = self.clock.local_hour();
        let minute = self.clock.local_minute();
        let (md, mdf) = self.min_demand();

        // 0. Expire inhibitions.
        self.expire_inhibitions(now);

        // 0b. Warn about stale TRVs.
        for zone in &heating_config.zones {
            for zt in &zone.trvs {
                let trv = self.world.trv(&zt.device);
                if trv.is_stale(now) && trv.has_raw_demand(md, mdf) {
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

        // 0c. Wall thermostat keepalive: detect stale mains-powered devices.
        for zone in &heating_config.zones {
            let hz = self.world.heating_zone(&zone.name);
            if hz.is_wt_stale(now) {
                tracing::warn!(
                    zone = %zone.name,
                    relay = %zone.relay,
                    last_seen_secs_ago = hz.wt_last_seen
                        .map(|s| now.duration_since(s).as_secs())
                        .unwrap_or(0),
                    "wall thermostat stale: sending GET to provoke state report"
                );
                actions.push(Action::get_device_state(
                    zone.relay.clone(),
                    Payload::GetState { state: "" },
                ));
            }
        }

        // 0d. Periodic wall thermostat state refresh.
        let should_refresh = self.last_wt_refresh
            .map(|t| now.duration_since(t) >= WT_REFRESH_INTERVAL)
            .unwrap_or(true);
        if should_refresh {
            self.last_wt_refresh = Some(now);
            for zone in &heating_config.zones {
                actions.push(Action::get_device_state(
                    zone.relay.clone(),
                    Payload::GetState { state: "" },
                ));
            }
        }

        // 1. Pressure group enforcement (before schedule so released
        //    TRVs get their scheduled setpoint in the same tick).
        actions.extend(self.enforce_pressure_groups(now));

        // 2. Schedule evaluation.
        actions.extend(self.evaluate_schedules(weekday, hour, minute, now));

        // 2b. Reconcile setpoints.
        actions.extend(self.reconcile_setpoints());

        // 3. Open window detection.
        actions.extend(self.detect_open_windows(now));

        // 4. Relay control.
        actions.extend(self.evaluate_relays(now));

        // 5. Reconcile relays.
        actions.extend(self.reconcile_relays());

        // 6. HA discovery and state updates.
        actions.extend(self.emit_ha_updates(now));

        actions
    }

    // ---- Schedule evaluation --------------------------------------------------

    fn evaluate_schedules(
        &mut self,
        weekday: Weekday,
        hour: u8,
        minute: u8,
        now: Instant,
    ) -> Vec<Action> {
        let mut actions = Vec::new();
        let heating_config = match &self.heating_config {
            Some(c) => c.clone(),
            None => return actions,
        };
        let tick_gen = self.heating_tick_gen;

        for zone in &heating_config.zones {
            for zt in &zone.trvs {
                let Some(schedule) = heating_config.schedules.get(&zt.schedule) else {
                    continue;
                };
                let Some(target_temp) = schedule.target_temperature(weekday, hour, minute) else {
                    continue;
                };

                let trv = self.world.trv(&zt.device);

                // Skip forced/inhibited TRVs.
                if trv.is_forced_open() || trv.is_inhibited(now) {
                    continue;
                }

                // Dedup: skip if target already set and confirmed.
                if trv.target_setpoint() == Some(target_temp)
                    && trv.target.phase() == TargetPhase::Confirmed
                {
                    continue;
                }

                trv.target.set_and_command(
                    TrvTarget::Setpoint(target_temp),
                    Owner::Schedule,
                    now,
                );
                trv.setpoint_dirty_gen = tick_gen;
                actions.push(Action::for_device(
                    zt.device.clone(),
                    Payload::trv_setpoint(target_temp),
                ));

                tracing::info!(
                    trv = %zt.device,
                    target_temp,
                    weekday = %weekday,
                    time = format!("{hour:02}:{minute:02}"),
                    "schedule: setting TRV setpoint"
                );
            }
        }
        actions
    }

    // ---- Setpoint reconciliation ----------------------------------------------

    fn reconcile_setpoints(&self) -> Vec<Action> {
        let mut actions = Vec::new();
        let heating_config = match &self.heating_config {
            Some(c) => c,
            None => return actions,
        };

        for zone in &heating_config.zones {
            for zt in &zone.trvs {
                let trv = match self.world.trvs.get(&zt.device) {
                    Some(t) => t,
                    None => continue,
                };
                if !trv.needs_setpoint_retry() {
                    continue;
                }
                if trv.setpoint_dirty_gen == self.heating_tick_gen {
                    continue;
                }
                let target_sp = match trv.target.value() {
                    Some(TrvTarget::Setpoint(t)) => *t,
                    Some(TrvTarget::Inhibited { .. }) => MIN_SETPOINT,
                    Some(TrvTarget::ForcedOpen { .. }) => MAX_SETPOINT,
                    None => continue,
                };
                actions.push(Action::for_device(
                    zt.device.clone(),
                    Payload::trv_setpoint(target_sp),
                ));
                tracing::info!(
                    trv = %zt.device,
                    target = target_sp,
                    confirmed = false,
                    "reconcile: retrying unconfirmed setpoint"
                );
            }
        }
        actions
    }

    // ---- Pressure group enforcement -------------------------------------------

    fn enforce_pressure_groups(&mut self, now: Instant) -> Vec<Action> {
        let mut actions = Vec::new();
        let heating_config = match &self.heating_config {
            Some(c) => c.clone(),
            None => return actions,
        };
        let (md, mdf) = self.min_demand();
        let tick_gen = self.heating_tick_gen;

        for group in &heating_config.pressure_groups {
            // Organic demand: only non-forced, non-inhibited TRVs.
            let any_organic_demand = group.trvs.iter().any(|trv_name| {
                self.world.trvs.get(trv_name).is_some_and(|t| {
                    !t.is_forced_open()
                        && !t.is_inhibited(now)
                        && !t.needs_setpoint_retry() // release-pending
                        && t.has_raw_demand(md, mdf)
                })
            });

            // Zone relay must be ON (or pending ON) for pressure to be relevant.
            let zone_relay_off = group.trvs.first().and_then(|trv_name| {
                heating_config.zones.iter()
                    .find(|z| z.trvs.iter().any(|zt| zt.device == *trv_name))
                    .map(|z| {
                        let hz = self.world.heating_zones.get(&z.name);
                        hz.is_some_and(|hz| {
                            !hz.is_relay_on()
                                && hz.relay_state_known
                                && hz.target.value() != Some(&HeatingZoneTarget::Heating)
                        })
                    })
            }).unwrap_or(false);
            let group_active = any_organic_demand && !zone_relay_off;

            // Alert on stale TRVs with demand.
            for trv_name in &group.trvs {
                if let Some(t) = self.world.trvs.get(trv_name) {
                    if t.is_stale(now) && t.has_raw_demand(md, mdf) {
                        tracing::error!(
                            trv = %trv_name,
                            group = %group.name,
                            "FAULT: TRV in pressure group is stale with demand; \
                             group stays forced for flow safety — check device"
                        );
                    }
                }
            }

            for trv_name in &group.trvs {
                let trv = match self.world.trvs.get_mut(trv_name) {
                    Some(t) => t,
                    None => continue,
                };

                if group_active {
                    if trv.is_inhibited(now) {
                        continue;
                    }
                    // Already at MAX via min_cycle force.
                    if trv.target.value().is_some_and(|t| matches!(t, TrvTarget::ForcedOpen { reason: ForceOpenReason::MinCycle })) {
                        continue;
                    }
                    if !trv.is_forced_open() && !trv.has_raw_demand(md, mdf) {
                        trv.target.set_and_command(
                            TrvTarget::ForcedOpen { reason: ForceOpenReason::PressureGroup },
                            Owner::Rule,
                            now,
                        );
                        trv.last_force_reason = Some(ForceOpenReason::PressureGroup);
                        trv.setpoint_dirty_gen = tick_gen;
                        actions.push(Action::for_device(
                            trv_name.clone(),
                            Payload::trv_setpoint(MAX_SETPOINT),
                        ));
                        tracing::info!(
                            trv = %trv_name,
                            group = %group.name,
                            "pressure group: force-opening TRV (setpoint -> 30C)"
                        );
                    }
                } else if trv.target.value().is_some_and(|t| matches!(t, TrvTarget::ForcedOpen { reason: ForceOpenReason::PressureGroup })) {
                    if trv.is_inhibited(now) {
                        continue;
                    }
                    // Release: set to placeholder Commanded so the schedule
                    // evaluator overwrites with the real setpoint on the
                    // next tick. last_force_reason is cleared when that
                    // real setpoint is confirmed.
                    trv.target.set_and_command(TrvTarget::Setpoint(0.0), Owner::Schedule, now);
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

    // ---- Open window detection ------------------------------------------------

    fn detect_open_windows(&mut self, now: Instant) -> Vec<Action> {
        let mut actions = Vec::new();
        let heating_config = match &self.heating_config {
            Some(c) => c.clone(),
            None => return actions,
        };
        let detect_dur = Duration::from_secs(
            heating_config.open_window.detection_minutes as u64 * 60,
        );
        let inhibit_dur = Duration::from_secs(
            heating_config.open_window.inhibit_minutes as u64 * 60,
        );
        let inhibit_minutes = heating_config.open_window.inhibit_minutes;
        let tick_gen = self.heating_tick_gen;

        for zone in &heating_config.zones {
            let hz = match self.world.heating_zones.get(&zone.name) {
                Some(hz) => hz,
                None => continue,
            };
            if !hz.is_relay_on() {
                continue;
            }
            let Some(relay_on_since) = hz.relay_on_since else {
                continue;
            };
            if now.duration_since(relay_on_since) < detect_dur {
                continue;
            }

            for zt in &zone.trvs {
                let trv = match self.world.trvs.get_mut(&zt.device) {
                    Some(t) => t,
                    None => continue,
                };
                if trv.open_window.checked {
                    continue;
                }
                if trv.is_inhibited(now) || trv.is_forced_open() {
                    continue;
                }
                // Skip TRVs with no heat demand.
                let has_demand = trv.actual.value().is_some_and(|a| {
                    a.pi_heating_demand.unwrap_or(0) > 0
                        || a.running_state == HeatingRunningState::Heat
                });
                if !has_demand {
                    trv.open_window.checked = true;
                    continue;
                }

                let Some(temp_at_on) = trv.open_window.temp_at_relay_on else {
                    let grace = Duration::from_secs(5 * 60);
                    if now.duration_since(relay_on_since) >= detect_dur + grace {
                        trv.open_window.checked = true;
                        tracing::warn!(
                            trv = %zt.device, zone = %zone.name,
                            "open window check: no temperature received since \
                             relay ON — check TRV telemetry"
                        );
                    }
                    continue;
                };
                let Some(baseline_at) = trv.open_window.baseline_established_at else {
                    continue;
                };

                let min_observation = detect_dur / 2;
                let grace = Duration::from_secs(5 * 60);
                let has_post_baseline_sample = trv.last_temp_at
                    .is_some_and(|t| t > baseline_at);
                let observation_elapsed =
                    now.duration_since(baseline_at) >= min_observation;

                if !has_post_baseline_sample || !observation_elapsed {
                    let relay_deadline = relay_on_since + detect_dur + grace;
                    let baseline_deadline = baseline_at + min_observation + grace;
                    let effective_deadline = relay_deadline.max(baseline_deadline);
                    if now >= effective_deadline {
                        trv.open_window.checked = true;
                        tracing::warn!(
                            trv = %zt.device, zone = %zone.name,
                            "open window check: insufficient data within \
                             grace window — check TRV telemetry"
                        );
                    }
                    continue;
                }

                trv.open_window.checked = true;

                let peak = trv.open_window.temp_high_water.unwrap_or(temp_at_on);
                if peak <= temp_at_on + 0.1 {
                    trv.target.set_and_command(
                        TrvTarget::Inhibited { until: now + inhibit_dur },
                        Owner::Rule,
                        now,
                    );
                    trv.setpoint_dirty_gen = tick_gen;
                    actions.push(Action::for_device(
                        zt.device.clone(),
                        Payload::trv_setpoint(MIN_SETPOINT),
                    ));
                    tracing::warn!(
                        trv = %zt.device,
                        zone = %zone.name,
                        temp_at_on, peak, inhibit_minutes,
                        "open window detected: inhibiting TRV (setpoint -> 5C)"
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

    /// Un-inhibit TRVs whose inhibition timer has expired.
    fn expire_inhibitions(&mut self, now: Instant) {
        let heating_config = match &self.heating_config {
            Some(c) => c.clone(),
            None => return,
        };

        for zone in &heating_config.zones {
            for zt in &zone.trvs {
                let trv = self.world.trv(&zt.device);
                let expired = match trv.target.value() {
                    Some(TrvTarget::Inhibited { until }) => now >= *until,
                    _ => false,
                };
                if expired {
                    let relay_on = self.world.heating_zones.get(&zone.name)
                        .is_some_and(|hz| hz.is_relay_on());
                    let trv = self.world.trv(&zt.device);
                    // Clear inhibition: set placeholder for schedule to overwrite.
                    trv.target.set_and_command(TrvTarget::Setpoint(0.0), Owner::Schedule, now);
                    trv.target.confirm(now);
                    if relay_on {
                        // Restart detection from now with a fresh baseline so
                        // the TRV has at least `min_observation` to recover
                        // before being re-evaluated.
                        let baseline = if trv.has_fresh_temp(now) {
                            trv.actual.value().and_then(|a| a.local_temperature)
                        } else {
                            None
                        };
                        trv.open_window.start_detection(now, baseline);
                    } else {
                        trv.open_window.reset();
                    }
                    tracing::info!(
                        trv = %zt.device, zone = %zone.name,
                        "open window inhibition expired, schedule will restore setpoint"
                    );
                }
            }
        }
    }

    // ---- Relay control with global pump protection ----------------------------

    fn evaluate_relays(&mut self, now: Instant) -> Vec<Action> {
        let mut actions = Vec::new();
        let heating_config = match &self.heating_config {
            Some(c) => c.clone(),
            None => return actions,
        };
        let min_cycle = Duration::from_secs(heating_config.heat_pump.min_cycle_seconds);
        let min_pause = Duration::from_secs(heating_config.heat_pump.min_pause_seconds);
        let (md, mdf) = self.min_demand();
        let tick_gen = self.heating_tick_gen;

        // Snapshot per-zone state.
        struct ZoneDecision {
            zone_name: String,
            relay: String,
            has_demand: bool,
            relay_on: bool,
            target: Option<HeatingZoneTarget>,
        }
        let decisions: Vec<ZoneDecision> = heating_config.zones.iter()
            .filter_map(|zone| {
                let hz = self.world.heating_zones.get(&zone.name)?;
                if !hz.relay_state_known {
                    return None;
                }
                let has_demand = zone.trvs.iter().any(|zt| {
                    self.world.trvs.get(&zt.device)
                        .is_some_and(|t| t.has_effective_demand(now, md, mdf))
                });
                Some(ZoneDecision {
                    zone_name: zone.name.clone(),
                    relay: zone.relay.clone(),
                    has_demand,
                    relay_on: hz.is_relay_on(),
                    target: hz.target.value().cloned(),
                })
            })
            .collect();

        // --- Phase 1: ON requests ---
        for d in &decisions {
            if d.has_demand && d.target != Some(HeatingZoneTarget::Heating) {
                let allowed = if self.is_pump_running() {
                    true
                } else {
                    self.effective_pump_off_since()
                        .map(|off_at| now.duration_since(off_at) >= min_pause)
                        .unwrap_or(true)
                };
                if allowed {
                    actions.push(Action::for_device(d.relay.clone(), Payload::device_on()));
                    let hz = self.world.heating_zone(&d.zone_name);
                    hz.target.set_and_command(HeatingZoneTarget::Heating, Owner::Schedule, now);
                    hz.desired_relay_gen = tick_gen;
                    tracing::info!(
                        zone = %d.zone_name, relay = %d.relay,
                        pump_running = self.is_pump_running(),
                        "heating: requesting relay ON"
                    );
                }
            }
        }

        // --- Phase 2: stale-ON cancellations ---
        for d in &decisions {
            if !d.has_demand && !d.relay_on
                && d.target == Some(HeatingZoneTarget::Heating)
            {
                let cycle_ok = self.effective_pump_on_since()
                    .map(|on_at| now.duration_since(on_at) >= min_cycle)
                    .unwrap_or(true);
                if cycle_ok {
                    let hz = self.world.heating_zone(&d.zone_name);
                    hz.target.set_and_command(HeatingZoneTarget::Off, Owner::Schedule, now);
                    hz.desired_relay_gen = tick_gen;
                    actions.push(Action::for_device(d.relay.clone(), Payload::device_off()));
                    tracing::info!(
                        zone = %d.zone_name, relay = %d.relay,
                        "heating: cancelling stale relay ON (demand gone, min_cycle ok)"
                    );
                }
            }
        }

        // --- Phase 3: confirmed-ON relay OFF requests ---
        let want_off: Vec<&ZoneDecision> = decisions.iter()
            .filter(|d| {
                !d.has_demand
                    && d.target != Some(HeatingZoneTarget::Off)
                    && d.relay_on
            })
            .collect();

        if !want_off.is_empty() {
            let confirmed_on = self.active_relay_count();
            let pending_off_count = self.world.heating_zones.values()
                .filter(|hz| {
                    hz.is_relay_on()
                        && hz.target.value() == Some(&HeatingZoneTarget::Off)
                })
                .count();
            let safe_on = confirmed_on.saturating_sub(pending_off_count);
            let survivors = safe_on.saturating_sub(want_off.len());

            let has_pending_on = decisions.iter().any(|d| {
                !d.relay_on
                    && self.world.heating_zones.get(&d.zone_name)
                        .is_some_and(|hz| {
                            hz.target.value() == Some(&HeatingZoneTarget::Heating)
                                && hz.target.phase() == TargetPhase::Commanded
                        })
            });

            if survivors > 0 {
                for d in &want_off {
                    let hz = self.world.heating_zone(&d.zone_name);
                    hz.target.set_and_command(HeatingZoneTarget::Off, Owner::Schedule, now);
                    hz.desired_relay_gen = tick_gen;
                    actions.push(Action::for_device(d.relay.clone(), Payload::device_off()));
                    tracing::info!(
                        zone = %d.zone_name, relay = %d.relay,
                        "heating: requesting relay OFF (pump stays running)"
                    );
                }
            } else if has_pending_on {
                tracing::debug!(
                    zones_wanting_off = want_off.len(),
                    "heating: relay OFF deferred, bridging pump for pending ON"
                );
            } else {
                let cycle_ok = self.effective_pump_on_since()
                    .map(|on_at| now.duration_since(on_at) >= min_cycle)
                    .unwrap_or(true);
                if cycle_ok {
                    for d in &want_off {
                        let hz = self.world.heating_zone(&d.zone_name);
                        hz.target.set_and_command(HeatingZoneTarget::Off, Owner::Schedule, now);
                        hz.desired_relay_gen = tick_gen;
                        actions.push(Action::for_device(d.relay.clone(), Payload::device_off()));
                        tracing::info!(
                            zone = %d.zone_name, relay = %d.relay,
                            "heating: requesting relay OFF (pump stopping)"
                        );
                    }
                } else {
                    // Safety: can we force any TRV open?
                    let any_forceable = want_off.iter().any(|d| {
                        heating_config.zones.iter()
                            .find(|z| z.name == d.zone_name)
                            .is_some_and(|z| z.trvs.iter().any(|zt| {
                                self.world.trvs.get(&zt.device).is_some_and(|t| {
                                    !t.is_forced_open() && !t.is_inhibited(now)
                                })
                            }))
                    });
                    let any_already_open = want_off.iter().any(|d| {
                        heating_config.zones.iter()
                            .find(|z| z.name == d.zone_name)
                            .is_some_and(|z| z.trvs.iter().any(|zt| {
                                self.world.trvs.get(&zt.device)
                                    .is_some_and(|t| t.is_forced_open())
                            }))
                    });

                    if !any_forceable && !any_already_open {
                        // No open flow path — override min_cycle for overpressure safety.
                        for d in &want_off {
                            let hz = self.world.heating_zone(&d.zone_name);
                            hz.target.set_and_command(HeatingZoneTarget::Off, Owner::Schedule, now);
                            hz.desired_relay_gen = tick_gen;
                            actions.push(Action::for_device(d.relay.clone(), Payload::device_off()));
                            tracing::warn!(
                                zone = %d.zone_name, relay = %d.relay,
                                "min_cycle hold OVERRIDDEN: no forceable TRVs \
                                 (all inhibited), allowing relay OFF to prevent overpressure"
                            );
                        }
                    } else {
                        // Force TRVs open to maintain flow.
                        for d in &want_off {
                            if let Some(zone_cfg) = heating_config.zones.iter().find(|z| z.name == d.zone_name) {
                                for zt in &zone_cfg.trvs {
                                    let trv = match self.world.trvs.get_mut(&zt.device) {
                                        Some(t) => t,
                                        None => continue,
                                    };
                                    if trv.is_forced_open() || trv.is_inhibited(now) {
                                        continue;
                                    }
                                    trv.target.set_and_command(
                                        TrvTarget::ForcedOpen { reason: ForceOpenReason::MinCycle },
                                        Owner::Rule,
                                        now,
                                    );
                                    trv.last_force_reason = Some(ForceOpenReason::MinCycle);
                                    trv.setpoint_dirty_gen = tick_gen;
                                    actions.push(Action::for_device(
                                        zt.device.clone(),
                                        Payload::trv_setpoint(MAX_SETPOINT),
                                    ));
                                    tracing::info!(
                                        trv = %zt.device,
                                        zone = %d.zone_name,
                                        "min_cycle hold: force-opening TRV (setpoint -> 30C)"
                                    );
                                }
                            }
                        }
                        tracing::debug!(
                            zones_wanting_off = want_off.len(),
                            "heating: relay OFF blocked by min_cycle protection, TRVs forced open"
                        );
                    }
                }
            }
        }

        actions
    }

    // ---- Relay reconciliation -------------------------------------------------

    fn reconcile_relays(&self) -> Vec<Action> {
        let mut actions = Vec::new();
        let heating_config = match &self.heating_config {
            Some(c) => c,
            None => return actions,
        };

        for zone in &heating_config.zones {
            let Some(hz) = self.world.heating_zones.get(&zone.name) else {
                continue;
            };
            let Some(desired) = hz.target.value() else {
                continue;
            };
            if hz.desired_relay_gen == self.heating_tick_gen {
                continue;
            }

            let desired_on = matches!(desired, HeatingZoneTarget::Heating);
            let actual_on = hz.is_relay_on();

            let needs_retry = if desired_on != actual_on {
                hz.target.phase() == TargetPhase::Commanded
                    || hz.target.phase() == TargetPhase::Stale
            } else if !desired_on && hz.target.phase() == TargetPhase::Commanded {
                // Desired OFF but phase still commanded (lost echo for a cancelled ON).
                true
            } else {
                false
            };

            if !needs_retry {
                continue;
            }

            let payload = if desired_on {
                Payload::device_on()
            } else {
                Payload::device_off()
            };
            actions.push(Action::for_device(zone.relay.clone(), payload));
            tracing::info!(
                zone = %zone.name,
                relay = %zone.relay,
                desired = desired_on,
                "reconcile: retrying unconfirmed relay command"
            );
        }
        actions
    }

    // ---- Device mode enforcement ----------------------------------------------

    fn check_trv_mode(&self, device: &str) -> Vec<Action> {
        let Some(trv) = self.world.trvs.get(device) else {
            return Vec::new();
        };
        let mode = trv.actual.value()
            .and_then(|a| a.operating_mode.as_deref());
        match mode {
            Some("manual") | None => Vec::new(),
            Some(m) => {
                tracing::warn!(
                    trv = %device,
                    current_mode = m,
                    "TRV operating_mode is not 'manual', reasserting"
                );
                vec![Action::for_device(
                    device.to_string(),
                    Payload::OperatingMode { operating_mode: "manual" },
                )]
            }
        }
    }

    fn check_wt_mode(&self, device: &str) -> Vec<Action> {
        let heating_config = match &self.heating_config {
            Some(c) => c,
            None => return Vec::new(),
        };
        for zone in &heating_config.zones {
            if zone.relay != device {
                continue;
            }
            let Some(hz) = self.world.heating_zones.get(&zone.name) else {
                break;
            };
            return match hz.wt_operating_mode.as_deref() {
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

    // ---- HA discovery and state updates ---------------------------------------

    fn emit_ha_updates(&mut self, now: Instant) -> Vec<Action> {
        let mut actions = Vec::new();
        let heating_config = match &self.heating_config {
            Some(c) => c.clone(),
            None => return actions,
        };

        if !self.ha_discovery_published {
            self.ha_discovery_published = true;
            for zone in &heating_config.zones {
                actions.push(ha_discovery::zone_discovery_action(&zone.name));
                for zt in &zone.trvs {
                    actions.push(ha_discovery::trv_discovery_action(&zt.device));
                }
            }
        }

        let (md, mdf) = self.min_demand();
        let min_pause = heating_config.heat_pump.min_pause_seconds;
        for zone_cfg in &heating_config.zones {
            // Zone state
            let zone_derived = {
                let hz = self.world.heating_zones.get(&zone_cfg.name);
                hz.map(|hz| ha_discovery::derive_zone_state_from_tass(
                    hz, self, now, md, mdf, min_pause,
                )).unwrap_or(ha_discovery::ZoneDerivedState::Unknown)
            };
            let topic = ha_discovery::state_topic("zone", &zone_cfg.name);
            let state_str = zone_derived.as_str();
            if self.ha_last_published.get(&topic).map_or(true, |prev| prev != state_str) {
                let hz = self.world.heating_zones.get(&zone_cfg.name);
                tracing::info!(
                    zone = %zone_cfg.name,
                    from = self.ha_last_published.get(&topic).map(String::as_str).unwrap_or("(none)"),
                    to = state_str,
                    relay_on = hz.is_some_and(|h| h.is_relay_on()),
                    relay_state_known = hz.map_or(false, |h| h.relay_state_known),
                    "HA zone state transition"
                );
                actions.push(ha_discovery::state_update_action("zone", &zone_cfg.name, state_str));
                self.ha_last_published.insert(topic, state_str.to_string());
            }

            // TRV states
            for zt in &zone_cfg.trvs {
                let trv_derived = self.world.trvs.get(&zt.device)
                    .map(|trv| ha_discovery::derive_trv_state_from_tass(trv, now, md, mdf))
                    .unwrap_or(ha_discovery::TrvDerivedState::Unknown);
                let topic = ha_discovery::state_topic("trv", &zt.device);
                let state_str = trv_derived.as_str();
                if self.ha_last_published.get(&topic).map_or(true, |prev| prev != state_str) {
                    actions.push(ha_discovery::state_update_action("trv", &zt.device, state_str));
                    self.ha_last_published.insert(topic, state_str.to_string());
                }
            }
        }
        actions
    }

    // ---- Pump tracking helpers ------------------------------------------------

    fn min_demand(&self) -> (u8, u8) {
        self.heating_config.as_ref()
            .map(|c| (c.heat_pump.min_demand_percent, c.heat_pump.min_demand_percent_fallback))
            .unwrap_or((5, 80))
    }

    /// True if any zone's relay is currently on.
    pub(crate) fn is_pump_running(&self) -> bool {
        self.world.heating_zones.values().any(|hz| hz.is_relay_on())
    }

    /// Count of zones with relay currently on.
    fn active_relay_count(&self) -> usize {
        self.world.heating_zones.values().filter(|hz| hz.is_relay_on()).count()
    }

    /// Effective pump-on timestamp: earliest among confirmed on_since and
    /// pending ON commands (excluding zones being cancelled).
    pub(crate) fn effective_pump_on_since(&self) -> Option<Instant> {
        let earliest_pending = self.world.heating_zones.values()
            .filter(|hz| hz.target.value() == Some(&HeatingZoneTarget::Heating))
            .filter_map(|hz| hz.target.since())
            .min();
        match (self.pump_on_since, earliest_pending) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }
    }

    /// Effective pump-off timestamp: most recent of confirmed off and
    /// pending OFF commands.
    pub(crate) fn effective_pump_off_since(&self) -> Option<Instant> {
        let latest_pending = self.world.heating_zones.values()
            .filter(|hz| {
                hz.target.value() == Some(&HeatingZoneTarget::Off)
                    && hz.target.phase() == TargetPhase::Commanded
            })
            .filter_map(|hz| hz.target.since())
            .max();
        match (self.pump_off_since, latest_pending) {
            (Some(a), Some(b)) => Some(a.max(b)),
            (a, b) => a.or(b),
        }
    }
}

// ---- Tests -----------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::heating::*;
    use crate::config::{CommonFields, Config, Defaults, DeviceCatalogEntry};
    use crate::logic::EventProcessor;
    use crate::time::{Clock, FakeClock};
    use crate::topology::Topology;
    use std::collections::BTreeMap;
    use std::sync::Arc;

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
                start_hour: 0, start_minute: 0,
                end_hour: 8, end_minute: 0,
                temperature: night_temp,
            },
            DayTimeRange {
                start_hour: 8, start_minute: 0,
                end_hour: 22, end_minute: 0,
                temperature: day_temp,
            },
            DayTimeRange {
                start_hour: 22, start_minute: 0,
                end_hour: 24, end_minute: 0,
                temperature: night_temp,
            },
        ]
    }

    fn trv_dev(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Trv(CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::from([
                ("operating_mode".into(), serde_json::json!("manual")),
            ]),
        })
    }

    fn wt_dev(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::WallThermostat(CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::from([
                ("heater_type".into(), serde_json::json!("manual_control")),
                ("operating_mode".into(), serde_json::json!("manual")),
            ]),
        })
    }

    fn make_config(
        zones: Vec<HeatingZone>,
        schedules: BTreeMap<String, TemperatureSchedule>,
        pressure_groups: Vec<PressureGroup>,
    ) -> Config {
        let mut devices: BTreeMap<String, DeviceCatalogEntry> = BTreeMap::new();
        for zone in &zones {
            devices.insert(zone.relay.clone(), wt_dev(&format!("0x{}", zone.relay)));
            for zt in &zone.trvs {
                devices.insert(zt.device.clone(), trv_dev(&format!("0x{}", zt.device)));
            }
        }
        Config {
            name_by_address: BTreeMap::new(),
            devices,
            rooms: vec![],
            switch_models: BTreeMap::new(),
            bindings: vec![],
            defaults: Defaults::default(),
            heating: Some(HeatingConfig {
                zones,
                schedules,
                pressure_groups,
                heat_pump: HeatPumpProtection {
                    min_cycle_seconds: 120,
                    min_pause_seconds: 60,
                    min_demand_percent: 5,
                    min_demand_percent_fallback: 80,
                },
                open_window: OpenWindowProtection {
                    detection_minutes: 20,
                    inhibit_minutes: 80,
                },
            }),
            location: None,
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
                TemperatureSchedule { days: full_week(20.0) },
            )]),
            vec![],
        )
    }

    fn setup(cfg: &Config) -> (EventProcessor, Arc<FakeClock>) {
        let clk = Arc::new(FakeClock::new(12));
        let topo = Arc::new(Topology::build(cfg).unwrap());
        let defaults = cfg.defaults.clone();
        let mut ep = EventProcessor::new(topo, clk.clone(), defaults, None);
        // Simulate startup: mark all zones as relay-state-known (OFF),
        // seed pump_off_since, mark startup complete and WT refreshed.
        let heating_config = cfg.heating.as_ref().unwrap();
        for zone in &heating_config.zones {
            let hz = ep.world.heating_zone(&zone.name);
            hz.relay_state_known = true;
            hz.actual.update(HeatingZoneActual { relay_on: false, temperature: None }, clk.now());
        }
        ep.pump_off_since = Some(clk.now());
        ep.startup_complete = true;
        clk.advance(Duration::from_secs(120));
        ep.last_wt_refresh = Some(clk.now());
        (ep, clk)
    }

    fn echo_relay(ep: &mut EventProcessor, relay: &str, on: bool, clk: &FakeClock) {
        ep.handle_event(Event::WallThermostatState {
            device: relay.into(),
            relay_on: Some(on),
            local_temperature: None,
            operating_mode: None,
            ts: clk.now(),
        });
    }

    fn echo_setpoint(ep: &mut EventProcessor, trv: &str, temp: f64, clk: &FakeClock) {
        ep.handle_event(Event::TrvState {
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

    fn send_trv_demand(ep: &mut EventProcessor, trv: &str, temp: f64, demand: u8, state: &str, setpoint: f64, clk: &FakeClock) {
        ep.handle_event(Event::TrvState {
            device: trv.into(),
            local_temperature: Some(temp),
            pi_heating_demand: Some(demand),
            running_state: Some(state.into()),
            occupied_heating_setpoint: Some(setpoint),
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
    }

    fn tick(ep: &mut EventProcessor) -> Vec<Action> {
        let ts = ep.clock.now();
        ep.handle_event(Event::Tick { ts })
    }

    // -- Schedule tests --

    #[test]
    fn schedule_sets_initial_setpoint() {
        let cfg = simple_config();
        let (mut ep, _clk) = setup(&cfg);
        let actions = tick(&mut ep);
        let sp: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "trv-bath-1")
            .collect();
        assert!(!sp.is_empty());
        let json = serde_json::to_string(&sp[0].payload).unwrap();
        assert!(json.contains("20"));
    }

    #[test]
    fn schedule_dedup_skips_redundant_setpoint() {
        let cfg = simple_config();
        let (mut ep, clk) = setup(&cfg);
        tick(&mut ep);
        echo_setpoint(&mut ep, "trv-bath-1", 20.0, &clk);
        let actions = tick(&mut ep);
        let sp: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "trv-bath-1")
            .collect();
        assert!(sp.is_empty(), "should not re-send confirmed setpoint");
    }

    #[test]
    fn schedule_retries_unconfirmed_setpoint() {
        let cfg = simple_config();
        let (mut ep, _clk) = setup(&cfg);
        tick(&mut ep);
        let actions = tick(&mut ep);
        let sp: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "trv-bath-1")
            .collect();
        assert!(!sp.is_empty(), "should retry unconfirmed setpoint");
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
                trvs: vec![ZoneTrv { device: "trv-bath-1".into(), schedule: "sched".into() }],
            }],
            BTreeMap::from([("sched".into(), TemperatureSchedule { days })]),
            vec![],
        );
        let (mut ep, clk) = setup(&cfg);
        let actions = tick(&mut ep);
        assert!(!actions.is_empty());
        let json = serde_json::to_string(&actions[0].payload).unwrap();
        assert!(json.contains("22"));
        echo_setpoint(&mut ep, "trv-bath-1", 22.0, &clk);
        clk.set_hour(23);
        let actions = tick(&mut ep);
        let sp: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "trv-bath-1"
                && serde_json::to_string(&a.payload).unwrap().contains("18"))
            .collect();
        assert!(!sp.is_empty(), "should set new target on time change");
    }

    // -- Demand and relay tests --

    #[test]
    fn relay_turns_on_when_trv_demands_heat() {
        let cfg = simple_config();
        let (mut ep, clk) = setup(&cfg);
        tick(&mut ep);
        send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
        let actions = tick(&mut ep);
        let relay_on: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "wt-bath"
                && serde_json::to_string(&a.payload).unwrap().contains("ON"))
            .collect();
        assert!(!relay_on.is_empty(), "should request relay ON");
    }

    #[test]
    fn relay_turns_off_when_demand_stops() {
        let cfg = simple_config();
        let (mut ep, clk) = setup(&cfg);
        tick(&mut ep);
        send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
        tick(&mut ep);
        echo_relay(&mut ep, "wt-bath", true, &clk);
        clk.advance(Duration::from_secs(200));
        send_trv_demand(&mut ep, "trv-bath-1", 20.5, 0, "idle", 20.0, &clk);
        let actions = tick(&mut ep);
        let relay_off: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "wt-bath"
                && serde_json::to_string(&a.payload).unwrap().contains("OFF"))
            .collect();
        assert!(!relay_off.is_empty(), "should request relay OFF");
    }

    // -- Short cycling tests --

    #[test]
    fn min_pause_blocks_relay_on() {
        let cfg = simple_config();
        let (mut ep, clk) = setup(&cfg);
        tick(&mut ep);
        ep.pump_off_since = Some(clk.now());
        clk.advance(Duration::from_secs(30));
        send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
        let actions = tick(&mut ep);
        let relay_on: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "wt-bath"
                && serde_json::to_string(&a.payload).unwrap().contains("ON"))
            .collect();
        assert!(relay_on.is_empty(), "should block relay ON during min_pause");
        clk.advance(Duration::from_secs(40));
        let actions = tick(&mut ep);
        let relay_on: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "wt-bath"
                && serde_json::to_string(&a.payload).unwrap().contains("ON"))
            .collect();
        assert!(!relay_on.is_empty(), "should allow relay ON after min_pause");
    }

    #[test]
    fn min_cycle_blocks_relay_off() {
        let cfg = simple_config();
        let (mut ep, clk) = setup(&cfg);
        tick(&mut ep);
        send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
        tick(&mut ep);
        echo_relay(&mut ep, "wt-bath", true, &clk);
        send_trv_demand(&mut ep, "trv-bath-1", 20.5, 0, "idle", 20.0, &clk);
        clk.advance(Duration::from_secs(60));
        let actions = tick(&mut ep);
        let relay_off: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "wt-bath"
                && serde_json::to_string(&a.payload).unwrap().contains("OFF"))
            .collect();
        assert!(relay_off.is_empty(), "should block relay OFF during min_cycle");
        clk.advance(Duration::from_secs(120));
        let actions = tick(&mut ep);
        let relay_off: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "wt-bath"
                && serde_json::to_string(&a.payload).unwrap().contains("OFF"))
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
        let (mut ep, clk) = setup(&cfg);
        tick(&mut ep);
        send_trv_demand(&mut ep, "trv-1", 18.0, 50, "heat", 20.0, &clk);
        tick(&mut ep);
        echo_relay(&mut ep, "wt-bath", true, &clk);
        let actions = tick(&mut ep);
        let forced: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "trv-2"
                && serde_json::to_string(&a.payload).unwrap().contains("30"))
            .collect();
        assert_eq!(forced.len(), 1, "trv-2 should be forced to 30C");
    }

    // -- Open window tests --

    #[test]
    fn open_window_inhibits_trv() {
        let mut cfg = simple_config();
        cfg.heating.as_mut().unwrap().open_window = OpenWindowProtection {
            detection_minutes: 1,
            inhibit_minutes: 2,
        };
        let (mut ep, clk) = setup(&cfg);
        tick(&mut ep);
        send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
        tick(&mut ep);
        echo_relay(&mut ep, "wt-bath", true, &clk);
        clk.advance(Duration::from_secs(5));
        send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
        clk.advance(Duration::from_secs(65));
        send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
        let actions = tick(&mut ep);
        let inhibit: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "trv-bath-1"
                && serde_json::to_string(&a.payload).unwrap().contains("\"occupied_heating_setpoint\":5"))
            .collect();
        assert!(!inhibit.is_empty(), "TRV should be inhibited via setpoint 5C");
        let trv = ep.world.trvs.get("trv-bath-1").unwrap();
        assert!(trv.is_inhibited(clk.now()));
    }

    // -- Mode enforcement --

    #[test]
    fn trv_mode_drift_triggers_reassertion() {
        let cfg = simple_config();
        let (mut ep, clk) = setup(&cfg);
        tick(&mut ep);
        let actions = ep.handle_event(Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(20.0),
            pi_heating_demand: None,
            running_state: None,
            occupied_heating_setpoint: None,
            operating_mode: Some("schedule".into()),
            battery: None,
            ts: clk.now(),
        });
        let mode: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "trv-bath-1"
                && serde_json::to_string(&a.payload).unwrap().contains("manual"))
            .collect();
        assert!(!mode.is_empty(), "TRV mode drift must trigger reassertion");
    }

    #[test]
    fn wall_thermostat_mode_drift_triggers_reassertion() {
        let cfg = simple_config();
        let (mut ep, clk) = setup(&cfg);
        tick(&mut ep);
        let actions = ep.handle_event(Event::WallThermostatState {
            device: "wt-bath".into(),
            relay_on: Some(false),
            local_temperature: Some(22.0),
            operating_mode: Some("schedule".into()),
            ts: clk.now(),
        });
        let mode: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "wt-bath"
                && serde_json::to_string(&a.payload).unwrap().contains("manual"))
            .collect();
        assert!(!mode.is_empty(), "wall thermostat mode drift must trigger reassertion");
    }

    // -- Reconciliation tests --

    #[test]
    fn relay_reconciliation_retries_unconfirmed() {
        let cfg = simple_config();
        let (mut ep, clk) = setup(&cfg);
        tick(&mut ep);
        send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
        tick(&mut ep); // emits relay ON
        // No echo.
        let actions = tick(&mut ep);
        let relay_on: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "wt-bath"
                && serde_json::to_string(&a.payload).unwrap().contains("ON"))
            .collect();
        assert!(!relay_on.is_empty(), "should retry unconfirmed relay ON");
    }

    #[test]
    fn setpoint_reconciliation_retries_on_divergence() {
        let cfg = simple_config();
        let (mut ep, clk) = setup(&cfg);
        tick(&mut ep); // sets setpoint to 20.0
        ep.handle_event(Event::TrvState {
            device: "trv-bath-1".into(),
            local_temperature: Some(18.0),
            pi_heating_demand: None,
            running_state: None,
            occupied_heating_setpoint: Some(15.0), // wrong
            operating_mode: None,
            battery: None,
            ts: clk.now(),
        });
        let actions = tick(&mut ep);
        let retries: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "trv-bath-1"
                && serde_json::to_string(&a.payload).unwrap().contains("20"))
            .collect();
        assert!(!retries.is_empty(), "should retry diverged setpoint");
    }

    #[test]
    fn no_duplicate_commands_on_same_tick() {
        let cfg = simple_config();
        let (mut ep, _clk) = setup(&cfg);
        let actions = tick(&mut ep);
        let sp: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "trv-bath-1")
            .collect();
        assert_eq!(sp.len(), 1, "should emit exactly one setpoint command per tick");
    }

    // -- Min cycle forcing --

    #[test]
    fn min_cycle_forces_trvs_open_when_blocking_relay_off() {
        let cfg = simple_config();
        let (mut ep, clk) = setup(&cfg);
        tick(&mut ep);
        send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
        tick(&mut ep);
        echo_relay(&mut ep, "wt-bath", true, &clk);
        send_trv_demand(&mut ep, "trv-bath-1", 20.5, 0, "idle", 20.0, &clk);
        clk.advance(Duration::from_secs(60));
        let actions = tick(&mut ep);
        let relay_off: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "wt-bath"
                && serde_json::to_string(&a.payload).unwrap().contains("OFF"))
            .collect();
        assert!(relay_off.is_empty(), "relay OFF should be blocked by min_cycle");
        let trv_forced: Vec<_> = actions.iter()
            .filter(|a| a.target_name() == "trv-bath-1"
                && serde_json::to_string(&a.payload).unwrap().contains("30"))
            .collect();
        assert!(!trv_forced.is_empty(), "TRV should be forced to 30C during min_cycle hold");
        let trv = ep.world.trvs.get("trv-bath-1").unwrap();
        assert!(trv.is_forced_open());
    }
}
