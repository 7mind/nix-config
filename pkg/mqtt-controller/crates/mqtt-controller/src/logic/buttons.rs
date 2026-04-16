//! Button dispatch logic: press handling, double-tap detection, and effect
//! execution.
//!
//! Routes button events through hardware double-tap suppression,
//! soft double-tap deferral, or direct dispatch depending on gesture
//! and topology configuration.

use std::time::{Duration, Instant};

use crate::config::switch_model::Gesture;
use crate::domain::Effect;
use crate::domain::action::Payload;
use crate::entities::PendingPress;
use crate::entities::light_zone::LightZoneTarget;
use crate::entities::plug::PlugTarget;
use crate::tass::Owner;
use crate::topology::{BindingIdx, ResolvedEffect};

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
    ) -> Vec<Effect> {
        tracing::info!(device, button, gesture = ?gesture, "button_event");
        let Some(device_idx) = self.topology.device_idx(device) else {
            // Unknown device — no bindings can match.
            return Vec::new();
        };
        match gesture {
            Gesture::DoubleTap => {
                let key = (device.to_string(), button.to_string());
                if let Some(pending) = self.world.pending_presses.remove(&key) {
                    if pending.already_fired {
                        // Press was early-fired (room was OFF); the room is
                        // now turning on, so DoubleTap would be redundant.
                        // Do NOT record last_double_tap — that would suppress
                        // subsequent single-press events for 2 seconds.
                        tracing::info!(
                            device,
                            button,
                            "suppressing double-tap (press was already early-fired)"
                        );
                        return Vec::new();
                    }
                    tracing::info!(
                        device,
                        button,
                        "cancelled deferred press (hardware double-tap arrived)"
                    );
                }
                // Record last_double_tap ONLY for real (non-suppressed) double-taps.
                // This starts the double_tap_suppression window that guards
                // against Sonoff firmware's inter-sequence cooldown quirk.
                self.world
                    .last_double_tap
                    .insert((device.to_string(), button.to_string()), ts);
                self.dispatch_bindings(device_idx, button, Gesture::DoubleTap, ts)
            }
            Gesture::Press => {
                // Check hardware double-tap suppression (Sonoff quirk):
                // after a DoubleTap, suppress Presses for a cooldown
                // window to guard against the firmware re-sending
                // `single` when the user double-taps again before the
                // inter-sequence cooldown has elapsed.
                if self.topology.is_hw_double_tap_button(device_idx, button) {
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
                    return self.handle_hw_double_tap_deferred_press(device, button, device_idx, ts);
                }
                if self.topology.is_soft_double_tap_button(device_idx, button) {
                    self.handle_soft_double_tap_press(device, button, device_idx, ts)
                } else {
                    self.dispatch_bindings(device_idx, button, Gesture::Press, ts)
                }
            }
            Gesture::SoftDoubleTap => {
                // This gesture is synthesized by the controller, never
                // from MQTT. Should not arrive here.
                Vec::new()
            }
            other => {
                // Hold, HoldRelease — dispatch directly, no deferral.
                self.dispatch_bindings(device_idx, button, other, ts)
            }
        }
    }

    /// Defer a press on a hardware-double-tap button. If a previous
    /// deferred press is still pending (user tapped again before the
    /// deferral window expired), flush it first, then buffer the new one.
    ///
    /// Early-fire optimization: when all Press bindings target rooms that
    /// are currently OFF, dispatch Press immediately (the result is the
    /// same for both Press and DoubleTap — turn on). The pending entry is
    /// kept with `already_fired: true` so that a late DoubleTap is
    /// suppressed and `flush_pending_presses` skips re-dispatch.
    fn handle_hw_double_tap_deferred_press(
        &mut self,
        device: &str,
        button: &str,
        device_idx: crate::topology::DeviceIdx,
        ts: Instant,
    ) -> Vec<Effect> {
        let key = (device.to_string(), button.to_string());
        let window =
            Duration::from_secs_f64(self.defaults.soft_double_tap_window_seconds);
        let mut out = Vec::new();
        // Flush any stale pending press before buffering the new one.
        if let Some(stale) = self.world.pending_presses.remove(&key) {
            if !stale.already_fired {
                tracing::info!(
                    device = %stale.device,
                    button = %stale.button,
                    "flushing stale deferred press (new press arrived)"
                );
                out.extend(self.dispatch_bindings(
                    device_idx,
                    &stale.button,
                    Gesture::Press,
                    stale.ts,
                ));
            }
        }
        let early_fire = self.can_early_fire_press(device_idx, button);
        if early_fire {
            tracing::info!(
                device,
                button,
                "early-firing press (all target rooms are OFF)"
            );
            out.extend(self.dispatch_bindings(device_idx, button, Gesture::Press, ts));
        } else {
            tracing::info!(
                device,
                button,
                window_ms = window.as_millis() as u64,
                "deferring press for hardware double-tap detection"
            );
        }
        self.world.pending_presses.insert(
            key,
            PendingPress {
                device: device.to_string(),
                button: button.to_string(),
                ts,
                deadline: ts + window,
                already_fired: early_fire,
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
        device_idx: crate::topology::DeviceIdx,
        ts: Instant,
    ) -> Vec<Effect> {
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
                    device_idx,
                    button,
                    Gesture::SoftDoubleTap,
                    ts,
                );
            }
            // Outside window — flush stale pending as press, then handle
            // new press (which also needs deferral).
            let out = self.dispatch_bindings(
                device_idx,
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
                    already_fired: false,
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
                already_fired: false,
            },
        );
        Vec::new()
    }

    /// Returns true if all Press bindings for (device, button) target rooms
    /// that are currently OFF. When true, firing Press immediately is safe
    /// because both Press and DoubleTap would produce the same result (turn on).
    fn can_early_fire_press(&self, device: crate::topology::DeviceIdx, button: &str) -> bool {
        let indexes = self.topology.bindings_for_button(device, button, Gesture::Press);
        if indexes.is_empty() {
            return false;
        }
        for &idx in indexes {
            let binding = self.topology.binding(idx);
            match &binding.effect {
                ResolvedEffect::SceneToggle { room }
                | ResolvedEffect::SceneCycle { room }
                | ResolvedEffect::SceneToggleCycle { room } => {
                    let room_name = &self.topology.room(*room).name;
                    match self.world.light_zones.get(room_name.as_str()) {
                        Some(z) if !z.is_on() && z.actual.is_known() => {
                            // Room exists, is known to be off — safe to early-fire
                        }
                        _ => return false, // Unknown, missing, or on — defer
                    }
                }
                _ => return false,
            }
        }
        true
    }

    /// Unified binding dispatch. Looks up matching bindings for the
    /// (device, button, gesture) triple and executes their effects.
    fn dispatch_bindings(
        &mut self,
        device: crate::topology::DeviceIdx,
        button: &str,
        gesture: Gesture,
        ts: Instant,
    ) -> Vec<Effect> {
        let indexes: Vec<BindingIdx> = self
            .topology
            .bindings_for_button(device, button, gesture)
            .to_vec();
        let bindings: Vec<(String, ResolvedEffect)> = indexes
            .iter()
            .map(|&idx| {
                let b = self.topology.binding(idx);
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
        effect: &ResolvedEffect,
        ts: Instant,
    ) -> Vec<Effect> {
        match effect {
            ResolvedEffect::SceneCycle { room } => {
                let room_name = self.topology.room(*room).name.clone();
                self.execute_scene_cycle(&room_name, ts)
            }
            ResolvedEffect::SceneToggle { room } => {
                let room_name = self.topology.room(*room).name.clone();
                self.execute_scene_toggle(&room_name, ts)
            }
            ResolvedEffect::SceneToggleCycle { room } => {
                let room_name = self.topology.room(*room).name.clone();
                self.execute_scene_toggle_cycle(&room_name, ts)
            }
            ResolvedEffect::TurnOffRoom { room } => {
                let room_name = self.topology.room(*room).name.clone();
                self.execute_turn_off_room(&room_name, ts)
            }
            ResolvedEffect::BrightnessStep {
                room,
                step,
                transition,
            } => {
                let room_name = self.topology.room(*room).name.clone();
                self.execute_brightness_step(&room_name, *step, *transition)
            }
            ResolvedEffect::BrightnessMove { room, rate } => {
                let room_name = self.topology.room(*room).name.clone();
                self.execute_brightness_move(&room_name, *rate)
            }
            ResolvedEffect::BrightnessStop { room } => {
                let room_name = self.topology.room(*room).name.clone();
                self.execute_brightness_stop(&room_name)
            }
            ResolvedEffect::Toggle {
                plug,
                confirm_off_seconds,
            } => {
                let target = self.topology.device_name(plug.device()).to_string();
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
                                let plug_entity = self.world.plug(&target);
                                plug_entity.target
                                    .set_and_command(PlugTarget::Off, Owner::User, ts);
                                plug_entity.on_off_clear_kill_switches();
                                return vec![Effect::PublishDeviceSet {
                                    device: plug.device(),
                                    payload: Payload::device_off(),
                                }];
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
                let plug_entity = self.world.plug(&target);
                plug_entity.target
                    .set_and_command(new_target, Owner::User, ts);
                if is_on {
                    plug_entity.on_off_clear_kill_switches();
                }
                vec![Effect::PublishDeviceSet { device: plug.device(), payload }]
            }
            ResolvedEffect::TurnOn { plug } => {
                let target = self.topology.device_name(plug.device()).to_string();
                tracing::info!(
                    rule = rule_name,
                    target = target.as_str(),
                    "action rule → turn on plug"
                );
                let plug_entity = self.world.plug(&target);
                plug_entity.target
                    .set_and_command(PlugTarget::On, Owner::User, ts);
                vec![Effect::PublishDeviceSet { device: plug.device(), payload: Payload::device_on() }]
            }
            ResolvedEffect::TurnOff { plug } => {
                let target = self.topology.device_name(plug.device()).to_string();
                tracing::info!(
                    rule = rule_name,
                    target = target.as_str(),
                    "action rule → turn off plug"
                );
                let plug_entity = self.world.plug(&target);
                plug_entity.target
                    .set_and_command(PlugTarget::Off, Owner::User, ts);
                plug_entity.on_off_clear_kill_switches();
                vec![Effect::PublishDeviceSet { device: plug.device(), payload: Payload::device_off() }]
            }
            ResolvedEffect::TurnOffAllZones => {
                tracing::info!(rule = rule_name, "action rule → turn off all zones");
                let mut out = Vec::new();
                for (room_idx, room) in self.topology.rooms_with_idx() {
                    let zone = self.world.light_zone(&room.name);
                    if zone.is_on() {
                        tracing::info!(
                            rule = rule_name,
                            room = room.name.as_str(),
                            group = room.group_name.as_str(),
                            "turning off zone"
                        );
                        // Only set target — actual updates come from
                        // z2m group echoes (TASS: actual = observations).
                        zone.target
                            .set_and_command(LightZoneTarget::Off, Owner::Schedule, ts);
                        zone.last_press_at = None;
                        zone.last_off_at = Some(ts);
                        out.push(Effect::PublishGroupSet {
                            room: room_idx,
                            payload: Payload::state_off(room.off_transition_seconds),
                        });
                    }
                }
                out
            }
        }
    }

    /// Flush all pending presses whose deadline has passed.
    pub(super) fn flush_pending_presses(&mut self, ts: Instant) -> Vec<Effect> {
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
            if pending.already_fired {
                tracing::info!(
                    device = %pending.device,
                    button = %pending.button,
                    "skipping flush for already early-fired press"
                );
                continue;
            }
            tracing::info!(
                device = %pending.device,
                button = %pending.button,
                "flushing deferred press (deferral window expired)"
            );
            // Look up the device idx; should always succeed for buffered presses
            // (the pending entry was created from a known device).
            if let Some(device_idx) = self.topology.device_idx(&pending.device) {
                out.extend(self.dispatch_bindings(
                    device_idx,
                    &pending.button,
                    Gesture::Press,
                    pending.ts,
                ));
            }
        }
        out
    }
}
