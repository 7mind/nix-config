//! Per-zone relay control with global heat-pump short-cycling
//! protection. The evaluator does the policy work (decide which zone
//! relays to switch and whether the heat pump's min-cycle/min-pause
//! windows allow it); the reconciler retries unconfirmed commands on
//! the next tick.

use std::time::{Duration, Instant};

use crate::config::heating::HeatingConfig;
use crate::domain::action::{Action, Payload};
use crate::entities::heating_zone::HeatingZoneTarget;
use crate::entities::trv::{ForceOpenReason, TrvTarget};
use crate::logic::EventProcessor;
use crate::tass::{Owner, TargetPhase};

use super::MAX_SETPOINT;

impl EventProcessor {
    pub(super) fn evaluate_relays(
        &mut self,
        heating_config: &HeatingConfig,
        now: Instant,
    ) -> Vec<Action> {
        let mut actions = Vec::new();
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

    pub(super) fn reconcile_relays(
        &self,
        heating_config: &HeatingConfig,
    ) -> Vec<Action> {
        let mut actions = Vec::new();

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
}
