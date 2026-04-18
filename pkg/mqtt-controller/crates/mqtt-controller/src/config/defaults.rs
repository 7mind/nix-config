//! Defaults block. Behavioural knobs that the Nix layer renders explicitly
//! after merging the user-supplied `defineRooms.defaults` with the helper's
//! built-in defaults. Living here in the JSON (rather than being hardcoded
//! in the Rust binary) means tuning is a config-only change — no rebuild
//! of the controller required.
//!
//! Brightness step/move values are now per-binding (in the effect params),
//! populated by Nix defaults during config generation.

use serde::{Deserialize, Serialize};

/// Top-level defaults the controller cares about.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields, default)]
pub struct Defaults {
    /// Window for `SceneToggleCycle` effect: within this window after a
    /// press, the next press cycles to the next scene instead of toggling
    /// off. Production default: 1.0 second.
    pub cycle_window_seconds: f64,

    /// After a hardware `double_tap` event, suppress `press` events from
    /// the same device+button for this many seconds. Guards against the
    /// Sonoff SNZB-01M firmware's ~2 s inter-sequence cooldown re-sending
    /// spurious singles after a double-tap.
    pub double_tap_suppression_seconds: f64,

    /// Window for software-detected double-taps. Two presses within this
    /// window fire `soft_double_tap` bindings instead of `press` bindings.
    /// Only active for (device, button) pairs that have at least one
    /// binding with `gesture: "soft_double_tap"`.
    pub soft_double_tap_window_seconds: f64,
}

impl Default for Defaults {
    fn default() -> Self {
        Self {
            cycle_window_seconds: 1.0,
            double_tap_suppression_seconds: 2.0,
            soft_double_tap_window_seconds: 0.8,
        }
    }
}

#[cfg(test)]
#[path = "defaults_tests.rs"]
mod tests;
