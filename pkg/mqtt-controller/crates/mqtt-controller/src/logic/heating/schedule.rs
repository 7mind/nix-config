//! Schedule evaluation and setpoint reconciliation. The schedule pass
//! pushes the time-of-day target onto every TRV; the reconcile pass
//! retries unconfirmed setpoint commands on the next tick.

use std::time::Instant;

use crate::config::heating::{HeatingConfig, Weekday};
use crate::domain::action::{Action, Payload};
use crate::entities::trv::TrvTarget;
use crate::logic::EventProcessor;
use crate::tass::{Owner, TargetPhase};

use super::{MAX_SETPOINT, MIN_SETPOINT};

impl EventProcessor {
    pub(super) fn evaluate_schedules(
        &mut self,
        heating_config: &HeatingConfig,
        weekday: Weekday,
        hour: u8,
        minute: u8,
        now: Instant,
    ) -> Vec<Action> {
        let mut actions = Vec::new();
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

    pub(super) fn reconcile_setpoints(
        &self,
        heating_config: &HeatingConfig,
    ) -> Vec<Action> {
        let mut actions = Vec::new();

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
}
