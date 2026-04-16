//! Pressure-group enforcement. When any TRV in a group has organic
//! demand, the others are force-opened to the max setpoint so the
//! valves stay flow-balanced. Released back to schedule control once
//! the demand drops away.

use std::time::Instant;

use crate::config::heating::HeatingConfig;
use crate::domain::Effect;
use crate::domain::action::Payload;
use crate::entities::heating_zone::HeatingZoneTarget;
use crate::entities::trv::{ForceOpenReason, TrvTarget};
use crate::logic::EventProcessor;
use crate::tass::Owner;

use super::MAX_SETPOINT;

impl EventProcessor {
    pub(super) fn enforce_pressure_groups(
        &mut self,
        heating_config: &HeatingConfig,
        now: Instant,
    ) -> Vec<Effect> {
        let mut actions = Vec::new();
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
                        if let Some(trv_idx) = self.topology.device_idx(trv_name) {
                            actions.push(Effect::PublishDeviceSet {
                                device: trv_idx,
                                payload: Payload::trv_setpoint(MAX_SETPOINT),
                            });
                        }
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
}
