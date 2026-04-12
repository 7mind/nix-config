//! Action-rule dispatch: trigger matching, effect execution,
//! confirm-off toggle, and scheduled `At` triggers.

use std::time::{Duration, Instant};

use crate::config::Effect;
use crate::domain::action::{Action, Payload};
use crate::domain::event::SwitchAction;

use super::Controller;

impl Controller {
    /// Execute action rules triggered by a switch press.
    pub(super) fn dispatch_switch_actions(
        &mut self,
        device: &str,
        action: SwitchAction,
        ts: Instant,
    ) -> Vec<Action> {
        let indexes = match action {
            SwitchAction::OnPressRelease => {
                self.topology.actions_for_switch_on(device).to_vec()
            }
            SwitchAction::OffPressRelease => {
                self.topology.actions_for_switch_off(device).to_vec()
            }
            _ => return Vec::new(),
        };
        self.execute_action_rules(&indexes, ts)
    }

    /// Execute action rules triggered by a tap button press.
    pub(super) fn dispatch_tap_actions(
        &mut self,
        device: &str,
        button: u8,
        action: Option<&str>,
        ts: Instant,
    ) -> Vec<Action> {
        let indexes = self.topology.actions_for_tap(device, button, action).to_vec();
        self.execute_action_rules(&indexes, ts)
    }

    /// Evaluate scheduled `At` triggers. Called on every tick.
    pub(super) fn evaluate_at_triggers(&mut self, ts: Instant) -> Vec<Action> {
        let sun = self.sun_times();
        let current_hour = self.clock.local_hour();
        let current_minute = self.clock.local_minute();
        let actions_snapshot = self.topology.actions().to_vec();
        let mut out = Vec::new();
        for resolved in &actions_snapshot {
            let time_expr = match &resolved.trigger {
                crate::config::Trigger::At { time } => time,
                _ => continue,
            };
            let resolved_minutes = time_expr.resolve(sun.as_ref());
            let target_hour = (resolved_minutes / 60) as u8;
            let target_minute = (resolved_minutes % 60) as u8;
            if current_hour == target_hour && current_minute == target_minute {
                let last = self.at_last_fired.get(&resolved.name);
                if last == Some(&(target_hour, target_minute)) {
                    continue; // already fired this minute
                }
                tracing::info!(
                    rule = resolved.name.as_str(),
                    time = %time_expr,
                    resolved_hour = target_hour,
                    resolved_minute = target_minute,
                    "scheduled trigger fired"
                );
                self.at_last_fired
                    .insert(resolved.name.clone(), (target_hour, target_minute));
                out.extend(self.execute_effect(&resolved.name, &resolved.effect, ts));
            } else {
                // Current time no longer matches — clear the dedup guard
                // so the rule fires again next time the target minute arrives.
                self.at_last_fired.remove(&resolved.name);
            }
        }
        out
    }

    fn execute_action_rules(&mut self, indexes: &[usize], ts: Instant) -> Vec<Action> {
        let rules: Vec<(String, Effect)> = indexes
            .iter()
            .map(|&idx| {
                let resolved = &self.topology.actions()[idx];
                (resolved.name.clone(), resolved.effect.clone())
            })
            .collect();
        let mut out = Vec::new();
        for (name, effect) in &rules {
            out.extend(self.execute_effect(name, effect, ts));
        }
        out
    }

    fn execute_effect(
        &mut self,
        rule_name: &str,
        effect: &Effect,
        ts: Instant,
    ) -> Vec<Action> {
        match effect {
            Effect::Toggle { target, confirm_off_seconds } => {
                let plug_state = self.plug_states.entry(target.to_string()).or_default();
                if plug_state.on {
                    if let Some(window) = confirm_off_seconds {
                        let window_dur = Duration::from_secs_f64(*window);
                        if let Some(pending_ts) = self.confirm_off_pending.remove(rule_name) {
                            if ts.duration_since(pending_ts) <= window_dur {
                                tracing::info!(
                                    rule = rule_name,
                                    target = target.as_str(),
                                    "action rule → confirm-off: second tap, turning off"
                                );
                                plug_state.on = false;
                                plug_state.seen_explicit_off = true;
                                plug_state.last_power = None;
                                self.kill_switch.on_plug_off(target);
                                return vec![Action::for_device(target, Payload::device_off())];
                            }
                        }
                        tracing::info!(
                            rule = rule_name,
                            target = target.as_str(),
                            window_seconds = window,
                            "action rule → confirm-off: armed, tap again to turn off"
                        );
                        self.confirm_off_pending.insert(rule_name.to_string(), ts);
                        return Vec::new();
                    }
                }
                self.confirm_off_pending.remove(rule_name);
                let new_on = !plug_state.on;
                let payload = if new_on { Payload::device_on() } else { Payload::device_off() };
                tracing::info!(
                    rule = rule_name,
                    target = target.as_str(),
                    from = plug_state.on,
                    to = new_on,
                    "action rule → toggle plug"
                );
                plug_state.on = new_on;
                if !new_on {
                    plug_state.seen_explicit_off = true;
                    plug_state.last_power = None;
                    self.kill_switch.on_plug_off(target);
                } else if plug_state.seen_explicit_off {
                    plug_state.last_power = None;
                    plug_state.seen_explicit_off = false;
                }
                vec![Action::for_device(target, payload)]
            }
            Effect::TurnOn { target } => {
                let plug_state = self.plug_states.entry(target.to_string()).or_default();
                tracing::info!(rule = rule_name, target = target.as_str(), "action rule → turn on plug");
                if plug_state.seen_explicit_off {
                    plug_state.last_power = None;
                }
                plug_state.on = true;
                plug_state.seen_explicit_off = false;
                vec![Action::for_device(target, Payload::device_on())]
            }
            Effect::TurnOff { target } => {
                let plug_state = self.plug_states.entry(target.to_string()).or_default();
                tracing::info!(rule = rule_name, target = target.as_str(), "action rule → turn off plug");
                plug_state.on = false;
                plug_state.seen_explicit_off = true;
                plug_state.last_power = None;
                self.kill_switch.on_plug_off(target);
                vec![Action::for_device(target, Payload::device_off())]
            }
            Effect::TurnOffAllZones => {
                tracing::info!(rule = rule_name, "action rule → turn off all zones");
                let mut out = Vec::new();
                for room in self.topology.rooms() {
                    let state = self.states.entry(room.name.clone()).or_default();
                    if state.physically_on {
                        tracing::info!(
                            rule = rule_name,
                            room = room.name.as_str(),
                            group = room.group_name.as_str(),
                            "turning off zone"
                        );
                        state.physically_on = false;
                        state.motion_owned = false;
                        state.cycle_idx = 0;
                        state.last_off_at = Some(ts);
                        out.push(Action::new(
                            &room.group_name,
                            Payload::state_off(room.off_transition_seconds),
                        ));
                    }
                }
                out
            }
        }
    }
}
