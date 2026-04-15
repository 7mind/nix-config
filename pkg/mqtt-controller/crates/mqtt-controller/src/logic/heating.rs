//! Heating logic adapter. Wraps the existing [`HeatingController`] and
//! syncs TASS entities from its internal state.
//!
//! The existing heating controller (4500+ lines) is battle-tested and
//! handles complex interactions (min_cycle, min_pause, pressure groups,
//! open window detection). Rather than rewrite it entirely, this adapter:
//!
//! 1. Forwards TRV/wall thermostat events to the existing controller
//! 2. After each event/tick, syncs TASS entities from the controller's state
//! 3. Provides TASS entity state for the frontend systems view
//!
//! This allows the frontend to show clean TASS state while keeping the
//! proven heating logic intact.

use std::sync::Arc;
use std::time::Instant;

use crate::controller::heating::HeatingController;
use crate::domain::action::Action;
use crate::domain::event::Event;
use crate::domain::heating_state::{HeatingRunningState, HeatingRuntimeState};
use crate::entities::heating_zone::{HeatingZoneActual, HeatingZoneTarget};
use crate::entities::trv::{ForceOpenReason, TrvActual, TrvTarget};
use crate::tass::Owner;

use super::EventProcessor;

impl EventProcessor {
    /// Initialize the heating sub-controller if config is present.
    pub fn init_heating(&mut self) {
        if let Some(config) = self.heating_config.clone() {
            let controller = HeatingController::new(
                config,
                self.topology.clone(),
                self.clock.clone(),
            );
            self.heating_controller = Some(controller);
        }
    }

    /// Forward a TRV or wall thermostat event to the heating controller
    /// and sync TASS entities.
    pub(super) fn handle_heating_event(&mut self, event: &Event) -> Vec<Action> {
        let Some(ref mut hc) = self.heating_controller else {
            return Vec::new();
        };
        let actions = hc.handle_event(event);
        self.sync_heating_entities();
        actions
    }

    /// Forward a tick to the heating controller and sync TASS entities.
    pub(super) fn handle_heating_tick(&mut self) -> Vec<Action> {
        let Some(ref mut hc) = self.heating_controller else {
            return Vec::new();
        };
        let actions = hc.handle_tick();
        self.sync_heating_entities();
        actions
    }

    /// Read-only access to the heating controller's runtime state.
    pub fn heating_state(&self) -> Option<&HeatingRuntimeState> {
        self.heating_controller.as_ref().map(|hc| hc.state())
    }

    /// Sync TASS heating entities from the existing controller's state.
    /// Called after every event/tick so the TASS entities reflect current state.
    fn sync_heating_entities(&mut self) {
        let Some(ref hc) = self.heating_controller else {
            return;
        };
        let state = hc.state();
        let now = self.clock.now();

        // Sync pump state
        self.world.heating_pump.pump_on_since = state.pump_on_since;
        self.world.heating_pump.pump_off_since = state.pump_off_since;

        // Sync per-zone state
        for (zone_name, zone_state) in &state.zones {
            let zone = self.world.heating_zone(zone_name);

            // Sync actual state
            zone.actual.update(
                HeatingZoneActual {
                    relay_on: zone_state.relay_on,
                    temperature: None, // temperature comes from wall thermostat
                },
                now,
            );
            zone.relay_state_known = zone_state.relay_state_known;
            zone.wt_operating_mode = zone_state.wt_operating_mode.clone();
            zone.wt_last_seen = zone_state.wt_last_seen;
            zone.relay_on_since = zone_state.relay_on_since;

            // Derive target from desired_relay
            match zone_state.desired_relay {
                Some(true) => {
                    if zone.target.value() != Some(&HeatingZoneTarget::Heating) {
                        zone.target
                            .set_and_command(HeatingZoneTarget::Heating, Owner::Schedule, now);
                    }
                    if zone_state.relay_on {
                        zone.target.confirm(now);
                    }
                }
                Some(false) => {
                    if zone.target.value() != Some(&HeatingZoneTarget::Off) {
                        zone.target
                            .set_and_command(HeatingZoneTarget::Off, Owner::Schedule, now);
                    }
                    if !zone_state.relay_on {
                        zone.target.confirm(now);
                    }
                }
                None => {} // target stays Unset
            }

            // Sync per-TRV state
            for (trv_name, trv_state) in &zone_state.trvs {
                let trv = self.world.trv(trv_name);
                trv.last_seen = trv_state.last_seen;
                trv.setpoint_dirty_gen = trv_state.setpoint_dirty_gen;

                // Sync actual
                let actual = TrvActual {
                    local_temperature: trv_state.local_temperature,
                    pi_heating_demand: trv_state.pi_heating_demand,
                    running_state: trv_state.running_state,
                    running_state_seen: trv_state.running_state_seen,
                    setpoint: trv_state.reported_setpoint,
                    operating_mode: trv_state.operating_mode.clone(),
                    battery: trv_state.battery,
                };
                trv.actual.update(actual, now);

                // Sync open window state
                trv.open_window.temp_at_relay_on = trv_state.temp_at_relay_on;
                trv.open_window.temp_high_water = trv_state.temp_high_water;
                trv.open_window.checked = trv_state.open_window_checked;
                trv.open_window.awaiting_baseline = trv_state.awaiting_temp_baseline;
                trv.open_window.baseline_established_at = trv_state.baseline_established_at;
                trv.open_window.temp_last_updated = trv_state.temp_last_updated;

                // Derive TRV target from controller state flags
                if trv_state.is_inhibited(now) {
                    let until = trv_state.inhibited_until.unwrap();
                    if trv.target.value() != Some(&TrvTarget::Inhibited { until }) {
                        trv.target
                            .set_and_command(TrvTarget::Inhibited { until }, Owner::Rule, now);
                    }
                } else if trv_state.pressure_forced {
                    if !trv.is_forced_open()
                        || trv.target.value()
                            != Some(&TrvTarget::ForcedOpen {
                                reason: ForceOpenReason::PressureGroup,
                            })
                    {
                        trv.target.set_and_command(
                            TrvTarget::ForcedOpen {
                                reason: ForceOpenReason::PressureGroup,
                            },
                            Owner::Rule,
                            now,
                        );
                    }
                } else if trv_state.min_cycle_forced {
                    if trv.target.value()
                        != Some(&TrvTarget::ForcedOpen {
                            reason: ForceOpenReason::MinCycle,
                        })
                    {
                        trv.target.set_and_command(
                            TrvTarget::ForcedOpen {
                                reason: ForceOpenReason::MinCycle,
                            },
                            Owner::Rule,
                            now,
                        );
                    }
                } else if let Some(setpoint) = trv_state.last_sent_setpoint {
                    if trv.target_setpoint() != Some(setpoint) {
                        trv.target
                            .set_and_command(TrvTarget::Setpoint(setpoint), Owner::Schedule, now);
                    }
                    if trv_state.setpoint_confirmed {
                        trv.target.confirm(now);
                    }
                }
            }
        }
    }
}
