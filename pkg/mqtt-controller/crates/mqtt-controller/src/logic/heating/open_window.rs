//! Open-window detection and inhibition expiry. When a TRV demands
//! heat but the room temperature doesn't rise within the detection
//! window, the TRV is inhibited (setpoint dropped to MIN) for a
//! configurable time so the heat pump doesn't fight an open window.

use std::time::{Duration, Instant};

use crate::config::heating::HeatingConfig;
use crate::domain::action::{Action, Payload};
use crate::entities::trv::{HeatingRunningState, TrvTarget};
use crate::logic::EventProcessor;
use crate::tass::Owner;

use super::MIN_SETPOINT;

impl EventProcessor {
    pub(super) fn detect_open_windows(
        &mut self,
        heating_config: &HeatingConfig,
        now: Instant,
    ) -> Vec<Action> {
        let mut actions = Vec::new();
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
    pub(super) fn expire_inhibitions(
        &mut self,
        heating_config: &HeatingConfig,
        now: Instant,
    ) {
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
}
