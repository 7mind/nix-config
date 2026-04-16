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

use crate::domain::action::{Action, Payload};
use crate::domain::event::Event;
use crate::entities::heating_zone::HeatingZoneTarget;
use crate::tass::TargetPhase;

use super::EventProcessor;

mod ha;
mod open_window;
mod pressure;
mod relay;
mod schedule;
mod telemetry;

pub(super) const MIN_SETPOINT: f64 = 5.0;
pub(super) const MAX_SETPOINT: f64 = 30.0;

/// Wall thermostat state refresh interval.
const WT_REFRESH_INTERVAL: Duration = Duration::from_secs(5 * 60);

/// Shared body of `check_trv_mode` / `check_wt_mode`: if the device's
/// reported `operating_mode` is anything other than "manual" or unknown,
/// re-issue a `mode=manual` command and warn. `device_kind` is used only
/// for the log message ("TRV" or "wall thermostat").
fn reassert_manual_mode_if_needed(
    device: &str,
    current_mode: Option<&str>,
    device_kind: &str,
) -> Vec<Action> {
    match current_mode {
        Some("manual") | None => Vec::new(),
        Some(m) => {
            tracing::warn!(
                device,
                current_mode = m,
                "{device_kind} operating_mode is not 'manual', reasserting"
            );
            vec![Action::for_device(
                device.to_string(),
                Payload::OperatingMode { operating_mode: "manual" },
            )]
        }
    }
}

impl EventProcessor {
    // ---- Event dispatch -------------------------------------------------------

    pub(super) fn handle_heating_event(&mut self, event: &Event) -> Vec<Action> {
        // Clone once at the dispatch boundary so the per-handler bodies
        // can borrow the config alongside `&mut self.world` without
        // fighting the borrow checker.
        let Some(heating_config) = self.heating_config.clone() else { return Vec::new() };
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
                    &heating_config,
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
                    &heating_config,
                    device, *relay_on, *local_temperature,
                    operating_mode.as_deref(), *ts,
                );
                self.check_wt_mode(device)
            }
            _ => Vec::new(),
        }
    }

    // ---- Tick handler ---------------------------------------------------------

    pub(super) fn handle_heating_tick(&mut self) -> Vec<Action> {
        self.heating_tick_gen += 1;
        let mut actions = Vec::new();

        let Some(heating_config) = self.heating_config.clone() else { return actions };

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
        self.expire_inhibitions(&heating_config, now);

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
        actions.extend(self.enforce_pressure_groups(&heating_config, now));

        // 2. Schedule evaluation.
        actions.extend(self.evaluate_schedules(&heating_config, weekday, hour, minute, now));

        // 2b. Reconcile setpoints.
        actions.extend(self.reconcile_setpoints(&heating_config));

        // 3. Open window detection.
        actions.extend(self.detect_open_windows(&heating_config, now));

        // 4. Relay control.
        actions.extend(self.evaluate_relays(&heating_config, now));

        // 5. Reconcile relays.
        actions.extend(self.reconcile_relays(&heating_config));

        // 6. HA discovery and state updates.
        actions.extend(self.emit_ha_updates(&heating_config, now));

        actions
    }
    // ---- Device mode enforcement ----------------------------------------------

    fn check_trv_mode(&self, device: &str) -> Vec<Action> {
        let mode = self.world.trvs.get(device)
            .and_then(|t| t.actual.value())
            .and_then(|a| a.operating_mode.as_deref());
        reassert_manual_mode_if_needed(device, mode, "TRV")
    }

    fn check_wt_mode(&self, device: &str) -> Vec<Action> {
        let Some(heating_config) = &self.heating_config else { return Vec::new() };
        let mode = heating_config.zones.iter()
            .find(|z| z.relay == device)
            .and_then(|z| self.world.heating_zones.get(&z.name))
            .and_then(|hz| hz.wt_operating_mode.as_deref());
        reassert_manual_mode_if_needed(device, mode, "wall thermostat")
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
mod tests;
