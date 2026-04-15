//! Button dispatch logic: press handling, double-tap detection, and effect
//! execution.
//!
//! Routes button events through hardware double-tap suppression,
//! soft double-tap deferral, or direct dispatch depending on gesture
//! and topology configuration.

use std::time::{Duration, Instant};

use crate::config::Effect;
use crate::config::switch_model::Gesture;
use crate::domain::action::{Action, Payload};
use crate::entities::PendingPress;
use crate::entities::light_zone::{LightZoneActual, LightZoneTarget};
use crate::entities::plug::PlugTarget;
use crate::tass::Owner;

use super::EventProcessor;

impl EventProcessor {
    /// Handle a button press event. Routes through hardware double-tap
    /// suppression, soft double-tap deferral, or direct dispatch
    /// depending on gesture and topology configuration.
    pub(super) fn handle_button_press(
        &mut self,
        device: &str,
        button: &str,
        gesture: Gesture,
        ts: Instant,
    ) -> Vec<Action> {
        tracing::info!(device, button, gesture = ?gesture, "button_event");
        match gesture {
            Gesture::DoubleTap => {
                self.world
                    .last_double_tap
                    .insert((device.to_string(), button.to_string()), ts);
                // Cancel any deferred press for this (device, button) —
                // the single was the first tap of this double-tap, not a
                // standalone press.
                let key = (device.to_string(), button.to_string());
                if self.world.pending_presses.remove(&key).is_some() {
                    tracing::info!(
                        device,
                        button,
                        "cancelled deferred press (hardware double-tap arrived)"
                    );
                }
                self.dispatch_bindings(device, button, Gesture::DoubleTap, ts)
            }
            Gesture::Press => {
                // Check hardware double-tap suppression (Sonoff quirk):
                // after a DoubleTap, suppress Presses for a cooldown
                // window to guard against the firmware re-sending
                // `single` when the user double-taps again before the
                // inter-sequence cooldown has elapsed.
                if self.topology.is_hw_double_tap_button(device, button) {
                    if let Some(&last_dt) = self
                        .world
                        .last_double_tap
                        .get(&(device.to_string(), button.to_string()))
                    {
                        let window = Duration::from_secs_f64(
                            self.defaults.double_tap_suppression_seconds,
                        );
                        if ts.duration_since(last_dt) < window {
                            tracing::info!(
                                device,
                                button,
                                "suppressing press within double-tap suppression window"
                            );
                            return Vec::new();
                        }
                    }
                    // Defer press: the firmware sends `single` before it
                    // knows whether a `double` is coming. Buffer the
                    // press and wait for either a DoubleTap (which
                    // cancels it) or the deferral window to expire.
                    return self.handle_hw_double_tap_deferred_press(device, button, ts);
                }
                if self.topology.is_soft_double_tap_button(device, button) {
                    self.handle_soft_double_tap_press(device, button, ts)
                } else {
                    self.dispatch_bindings(device, button, Gesture::Press, ts)
                }
            }
            Gesture::SoftDoubleTap => {
                // This gesture is synthesized by the controller, never
                // from MQTT. Should not arrive here.
                Vec::new()
            }
            other => {
                // Hold, HoldRelease — dispatch directly, no deferral.
                self.dispatch_bindings(device, button, other, ts)
            }
        }
    }

    /// Defer a press on a hardware-double-tap button. If a previous
    /// deferred press is still pending (user tapped again before the
    /// deferral window expired), flush it first, then buffer the new one.
    fn handle_hw_double_tap_deferred_press(
        &mut self,
        device: &str,
        button: &str,
        ts: Instant,
    ) -> Vec<Action> {
        let key = (device.to_string(), button.to_string());
        let window =
            Duration::from_secs_f64(self.defaults.soft_double_tap_window_seconds);
        let mut out = Vec::new();
        // Flush any stale pending press before buffering the new one.
        if let Some(stale) = self.world.pending_presses.remove(&key) {
            tracing::info!(
                device = %stale.device,
                button = %stale.button,
                "flushing stale deferred press (new press arrived)"
            );
            out.extend(self.dispatch_bindings(
                &stale.device,
                &stale.button,
                Gesture::Press,
                stale.ts,
            ));
        }
        tracing::info!(
            device,
            button,
            window_ms = window.as_millis() as u64,
            "deferring press for hardware double-tap detection"
        );
        self.world.pending_presses.insert(
            key,
            PendingPress {
                device: device.to_string(),
                button: button.to_string(),
                ts,
                deadline: ts + window,
            },
        );
        out
    }

    /// Handle a press event for a button that has soft-double-tap
    /// bindings. Buffers the first press; fires SoftDoubleTap on the
    /// second press within the window; flushes as Press on expiry.
    fn handle_soft_double_tap_press(
        &mut self,
        device: &str,
        button: &str,
        ts: Instant,
    ) -> Vec<Action> {
        let key = (device.to_string(), button.to_string());
        if let Some(pending) = self.world.pending_presses.remove(&key) {
            let window =
                Duration::from_secs_f64(self.defaults.soft_double_tap_window_seconds);
            if ts.duration_since(pending.ts) <= window {
                tracing::info!(
                    device,
                    button,
                    elapsed_ms = ts.duration_since(pending.ts).as_millis() as u64,
                    "soft double-tap detected"
                );
                return self.dispatch_bindings(
                    device,
                    button,
                    Gesture::SoftDoubleTap,
                    ts,
                );
            }
            // Outside window — flush stale pending as press, then handle
            // new press (which also needs deferral).
            let out = self.dispatch_bindings(
                &pending.device,
                &pending.button,
                Gesture::Press,
                pending.ts,
            );
            let window =
                Duration::from_secs_f64(self.defaults.soft_double_tap_window_seconds);
            self.world.pending_presses.insert(
                key,
                PendingPress {
                    device: device.to_string(),
                    button: button.to_string(),
                    ts,
                    deadline: ts + window,
                },
            );
            return out;
        }
        // First press — buffer it.
        let window =
            Duration::from_secs_f64(self.defaults.soft_double_tap_window_seconds);
        tracing::debug!(
            device,
            button,
            window_ms = window.as_millis() as u64,
            "deferring press for soft double-tap detection"
        );
        self.world.pending_presses.insert(
            key,
            PendingPress {
                device: device.to_string(),
                button: button.to_string(),
                ts,
                deadline: ts + window,
            },
        );
        Vec::new()
    }

    /// Unified binding dispatch. Looks up matching bindings for the
    /// (device, button, gesture) triple and executes their effects.
    fn dispatch_bindings(
        &mut self,
        device: &str,
        button: &str,
        gesture: Gesture,
        ts: Instant,
    ) -> Vec<Action> {
        let indexes: Vec<usize> = self
            .topology
            .bindings_for_button(device, button, gesture)
            .to_vec();
        let bindings: Vec<(String, Effect)> = indexes
            .iter()
            .map(|&idx| {
                let b = &self.topology.bindings()[idx];
                (b.name.clone(), b.effect.clone())
            })
            .collect();
        let mut out = Vec::new();
        for (name, effect) in &bindings {
            out.extend(self.execute_effect(name, effect, ts));
        }
        out
    }

    /// Execute a single effect. Handles both room-targeting and
    /// device-targeting effect variants.
    pub(super) fn execute_effect(
        &mut self,
        rule_name: &str,
        effect: &Effect,
        ts: Instant,
    ) -> Vec<Action> {
        match effect {
            Effect::SceneCycle { room } => self.execute_scene_cycle(room, ts),
            Effect::SceneToggle { room } => self.execute_scene_toggle(room, ts),
            Effect::SceneToggleCycle { room } => {
                self.execute_scene_toggle_cycle(room, ts)
            }
            Effect::TurnOffRoom { room } => self.execute_turn_off_room(room, ts),
            Effect::BrightnessStep {
                room,
                step,
                transition,
            } => self.execute_brightness_step(room, *step, *transition),
            Effect::BrightnessMove { room, rate } => {
                self.execute_brightness_move(room, *rate)
            }
            Effect::BrightnessStop { room } => self.execute_brightness_stop(room),
            Effect::Toggle {
                target,
                confirm_off_seconds,
            } => {
                let is_on = self.world.plugs.get(target.as_str()).is_some_and(|p| p.is_on());
                if is_on {
                    if let Some(window) = confirm_off_seconds {
                        let window_dur = Duration::from_secs_f64(*window);
                        if let Some(pending_ts) =
                            self.world.confirm_off_pending.remove(rule_name)
                        {
                            if ts.duration_since(pending_ts) <= window_dur {
                                tracing::info!(
                                    rule = rule_name,
                                    target = target.as_str(),
                                    "action rule → confirm-off: second tap, turning off"
                                );
                                let plug = self.world.plug(target);
                                plug.target
                                    .set_and_command(PlugTarget::Off, Owner::User, ts);
                                plug.on_off_clear_kill_switches();
                                return vec![Action::for_device(
                                    target,
                                    Payload::device_off(),
                                )];
                            }
                        }
                        tracing::info!(
                            rule = rule_name,
                            target = target.as_str(),
                            window_seconds = window,
                            "action rule → confirm-off: armed, tap again to turn off"
                        );
                        self.world
                            .confirm_off_pending
                            .insert(rule_name.to_string(), ts);
                        return Vec::new();
                    }
                }
                self.world.confirm_off_pending.remove(rule_name);
                let new_target = if is_on { PlugTarget::Off } else { PlugTarget::On };
                let payload = if is_on {
                    Payload::device_off()
                } else {
                    Payload::device_on()
                };
                tracing::info!(
                    rule = rule_name,
                    target = target.as_str(),
                    from = is_on,
                    to = !is_on,
                    "action rule → toggle plug"
                );
                let plug = self.world.plug(target);
                plug.target
                    .set_and_command(new_target, Owner::User, ts);
                if is_on {
                    plug.on_off_clear_kill_switches();
                }
                vec![Action::for_device(target, payload)]
            }
            Effect::TurnOn { target } => {
                tracing::info!(
                    rule = rule_name,
                    target = target.as_str(),
                    "action rule → turn on plug"
                );
                let plug = self.world.plug(target);
                plug.target
                    .set_and_command(PlugTarget::On, Owner::User, ts);
                vec![Action::for_device(target, Payload::device_on())]
            }
            Effect::TurnOff { target } => {
                tracing::info!(
                    rule = rule_name,
                    target = target.as_str(),
                    "action rule → turn off plug"
                );
                let plug = self.world.plug(target);
                plug.target
                    .set_and_command(PlugTarget::Off, Owner::User, ts);
                plug.on_off_clear_kill_switches();
                vec![Action::for_device(target, Payload::device_off())]
            }
            Effect::TurnOffAllZones => {
                tracing::info!(rule = rule_name, "action rule → turn off all zones");
                let mut out = Vec::new();
                for room in self.topology.rooms() {
                    let zone = self.world.light_zone(&room.name);
                    if zone.is_on() {
                        tracing::info!(
                            rule = rule_name,
                            room = room.name.as_str(),
                            group = room.group_name.as_str(),
                            "turning off zone"
                        );
                        zone.target
                            .set_and_command(LightZoneTarget::Off, Owner::User, ts);
                        zone.actual.update(LightZoneActual::Off, ts);
                        zone.last_press_at = None;
                        zone.last_off_at = Some(ts);
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

    /// Flush all pending presses whose deadline has passed.
    pub(super) fn flush_pending_presses(&mut self, ts: Instant) -> Vec<Action> {
        let expired: Vec<_> = self
            .world
            .pending_presses
            .iter()
            .filter(|(_, p)| ts >= p.deadline)
            .map(|(k, p)| (k.clone(), p.clone()))
            .collect();
        let mut out = Vec::new();
        for (key, pending) in expired {
            self.world.pending_presses.remove(&key);
            tracing::info!(
                device = %pending.device,
                button = %pending.button,
                "flushing deferred press (deferral window expired)"
            );
            out.extend(self.dispatch_bindings(
                &pending.device,
                &pending.button,
                Gesture::Press,
                pending.ts,
            ));
        }
        out
    }
}
