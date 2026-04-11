//! Plug state tracking and kill-switch integration.

use std::time::Instant;

use crate::domain::action::{Action, Payload};
use crate::domain::state::PlugRuntimeState;

use super::Controller;

impl Controller {
    /// Read-only peek at a plug's state.
    pub fn plug_state_for(&self, device: &str) -> Option<&PlugRuntimeState> {
        self.plug_states.get(device)
    }

    /// Set the physical-on flag for a plug directly. Used by the
    /// startup state-refresh routine.
    pub fn set_plug_state(&mut self, device: &str, on: bool) {
        let state = self.plug_states.entry(device.to_string()).or_default();
        state.on = on;
        if !on {
            state.seen_explicit_off = true;
            state.last_power = None;
            self.kill_switch.on_plug_off(device);
        }
    }

    /// Pre-arm kill-switch rules for every plug that is currently ON,
    /// and seed idle tracking from the current power reading if it is
    /// already below threshold.
    pub fn arm_kill_switches_for_active_plugs(&mut self, ts: Instant) {
        let active = self.plug_states.iter()
            .filter(|(_, p)| p.on)
            .map(|(name, p)| (name.as_str(), p.last_power))
            .collect::<Vec<_>>();
        self.kill_switch.arm_for_active_plugs(active.into_iter(), ts);
    }

    /// Handle a plug state or power update. When `on` is `Some`, the
    /// plug's on/off state is updated. When `None` (Z-Wave meter-only
    /// updates), the existing on/off state is preserved.
    pub(super) fn handle_plug_state(
        &mut self,
        device: &str,
        on: Option<bool>,
        power: Option<f64>,
        ts: Instant,
    ) -> Vec<Action> {
        let plug = self.plug_states.entry(device.to_string()).or_default();
        let was_on = plug.on;
        if let Some(on) = on {
            plug.on = on;
        }

        // Store power reading (uniformly clamped to ≥ 0).
        if let Some(watts) = power {
            let clamped = watts.max(0.0);
            plug.last_power = Some(clamped);
        }

        if !plug.on {
            // Only clear power and kill-switch state on an explicit off
            // transition. Power-only updates (on == None, e.g. Z-Wave
            // meter events) arriving before the switch state should
            // preserve last_power so arm_kill_switches_for_active_plugs
            // can seed idle tracking from it at startup.
            if on == Some(false) {
                plug.seen_explicit_off = true;
                plug.last_power = None;
                self.kill_switch.on_plug_off(device);
            }
            return Vec::new();
        }

        if on == Some(true) && !was_on {
            let plug = self.plug_states.entry(device.to_string()).or_default();
            let was_explicitly_off = plug.seen_explicit_off;
            plug.seen_explicit_off = false;

            // If the plug was explicitly off, any stored last_power is
            // from the off state and must be discarded.
            if was_explicitly_off {
                plug.last_power = power.map(|w| w.max(0.0));
            }

            let seed_power = {
                let plug = self.plug_states.get(device);
                power.map(|w| w.max(0.0))
                    .or_else(|| plug.and_then(|p| p.last_power))
            };

            self.kill_switch.on_plug_on(device, seed_power, ts);
        }

        // Compute effective power for kill-switch evaluation.
        let effective_power = {
            let plug = self.plug_states.get(device);
            power.map(|w| w.max(0.0))
                .or_else(|| plug.and_then(|p| p.last_power))
        };

        let Some(effective_power) = effective_power else {
            return Vec::new();
        };

        // Delegate to the kill-switch evaluator.
        let fired = self.kill_switch.evaluate(device, effective_power, ts);
        self.apply_kill_switch_fired(&fired)
    }

    /// Apply kill-switch results: update plug state and produce actions.
    pub(super) fn apply_kill_switch_fired(
        &mut self,
        fired: &[super::kill_switch::KillSwitchFired],
    ) -> Vec<Action> {
        let mut out = Vec::new();
        for f in fired {
            let plug = self.plug_states.entry(f.device.clone()).or_default();
            plug.on = false;
            plug.seen_explicit_off = true;
            plug.last_power = None;
            out.push(Action::for_device(&f.target, Payload::device_off()));
        }
        out
    }
}
