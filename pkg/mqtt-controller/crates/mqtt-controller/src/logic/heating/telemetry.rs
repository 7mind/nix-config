//! TRV and wall-thermostat state ingestion. Translates the latest
//! [`crate::domain::event::Event::TrvState`] /
//! [`crate::domain::event::Event::WallThermostatState`] payload into
//! a TASS update on the corresponding entity, with side effects on
//! pump tracking, open-window detection, and target confirmation.

use std::time::{Duration, Instant};

use crate::entities::heating_zone::{HeatingZoneActual, HeatingZoneTarget};
use crate::entities::trv::{ForceOpenReason, HeatingRunningState, TrvActual, TrvTarget};
use crate::logic::EventProcessor;
use crate::tass::{Owner, TargetPhase};

use super::{MAX_SETPOINT, MIN_SETPOINT};

impl EventProcessor {
    // ---- TRV state update -----------------------------------------------------
    
    pub(super) fn handle_trv_state(
        &mut self,
        heating_config: &crate::config::heating::HeatingConfig,
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
    
    pub(super) fn handle_wall_thermostat_state(
        &mut self,
        heating_config: &crate::config::heating::HeatingConfig,
        device: &str,
        relay_on: Option<bool>,
        local_temperature: Option<f64>,
        operating_mode: Option<&str>,
        _ts: Instant,
    ) {
        let now = self.clock.now();
    
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
        // First contact: seed `actual` even when the observed state
        // matches the default (was_on=false, on=false). Without this the
        // zone's actual stays Unknown forever for a zone that starts
        // off and never transitions.
        if first_contact {
            zone.actual.update(
                HeatingZoneActual { relay_on: on, temperature: local_temperature },
                now,
            );
        }

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
    
}
