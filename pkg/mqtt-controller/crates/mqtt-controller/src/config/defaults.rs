//! Defaults block. Behavioural knobs that the Nix layer renders explicitly
//! after merging the user-supplied `defineRooms.defaults` with the helper's
//! built-in defaults. Living here in the JSON (rather than being hardcoded
//! in the Rust binary) means tuning is a config-only change — no rebuild
//! of the controller required.
//!
//! Migration note: the bento helper had two separate cycle-window knobs —
//! `wall-switch.cycleDebounceSeconds` and `tap-switch.cyclePauseSeconds` —
//! with subtly different semantics (wall switch reset the cycle index after
//! the window; tap turned the zone OFF after the window). The new
//! controller unifies both into one [`Defaults::cycle_window_seconds`]
//! knob with the tap semantics applied to both: outside the window, the
//! cycle button toggles the zone OFF. Wall switches still have their
//! dedicated OFF action button which always fires immediately, so users
//! who relied on "tap on after window → restart cycle" can press the OFF
//! button instead.

use serde::{Deserialize, Serialize};

/// Top-level defaults the controller cares about. The Nix layer also
/// emits per-room and per-device defaults but those are inlined into the
/// room/device entries before they reach the binary, so this struct is
/// just the cross-cutting input behaviour.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields, default)]
pub struct Defaults {
    /// Window after a press of any cycle-capable button (wall switch
    /// `on`, tap button) during which the next press of the SAME button
    /// in the SAME room cycles to the next scene of the active slot.
    /// Outside the window, the next press toggles the zone OFF (the
    /// "expire" path).
    ///
    /// Production default: 1.0 second. Same value the bento helper had
    /// as `cycleDebounceSeconds` / `cyclePauseSeconds`.
    pub cycle_window_seconds: f64,

    /// After a `double_button_N` event, suppress `single_button_N` from
    /// the same device+button for this many seconds. Guards against the
    /// Sonoff SNZB-01M firmware's ~2 s inter-sequence cooldown: when the
    /// user double-taps again before the firmware fully resets, it sends
    /// `single` instead of `double`, which would toggle the room on/off.
    ///
    /// Only applies to device+button pairs with at least one
    /// `cycle_on_double_tap` room binding.
    pub double_tap_suppression_seconds: f64,

    /// Window for software-detected double-taps on Hue dimmer on/off
    /// buttons. Two presses within this window fire action rules with
    /// `action: "double"`. Single-press rules always fire immediately.
    pub switch_double_tap_window_seconds: f64,

    /// Wall-switch-specific brightness tuning. Taps don't have hold or
    /// up/down buttons so this section is unused for them.
    pub wall_switch: WallSwitchDefaults,
}

impl Default for Defaults {
    fn default() -> Self {
        Self {
            cycle_window_seconds: 1.0,
            double_tap_suppression_seconds: 2.0,
            switch_double_tap_window_seconds: 0.8,
            wall_switch: WallSwitchDefaults::default(),
        }
    }
}

/// Hue dimmer (wall switch) brightness tuning. The cycle window for wall
/// switches lives at the top level alongside the tap one — both share the
/// same [`Defaults::cycle_window_seconds`] value now.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct WallSwitchDefaults {
    /// Brightness step in 0..=254 units issued by `up`/`down` press
    /// release. The bento default is 25.
    pub brightness_step: i16,

    /// Transition for brightness step in seconds.
    pub brightness_step_transition_seconds: f64,

    /// Rate for brightness `_hold` events (continuous adjust). Units are
    /// z2m's `brightness_move`. Bento default is 40.
    pub brightness_move_rate: i16,
}

impl Default for WallSwitchDefaults {
    fn default() -> Self {
        Self {
            brightness_step: 25,
            brightness_step_transition_seconds: 0.2,
            brightness_move_rate: 40,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_defaults_round_trip() {
        let d: Defaults = serde_json::from_str("{}").unwrap();
        assert_eq!(d.cycle_window_seconds, 1.0);
        assert_eq!(d.double_tap_suppression_seconds, 2.0);
        assert_eq!(d.wall_switch.brightness_step, 25);
    }

    #[test]
    fn unified_cycle_window_override() {
        let d: Defaults = serde_json::from_str(
            r#"{
                "cycle_window_seconds": 0.5
            }"#,
        )
        .unwrap();
        assert_eq!(d.cycle_window_seconds, 0.5);
        // Wall switch still gets defaults.
        assert_eq!(d.wall_switch.brightness_step, 25);
    }

    #[test]
    fn partial_wall_switch_override_keeps_other_defaults() {
        let d: Defaults = serde_json::from_str(
            r#"{
                "wall_switch": {
                    "brightness_step": 50,
                    "brightness_step_transition_seconds": 0.4,
                    "brightness_move_rate": 60
                }
            }"#,
        )
        .unwrap();
        assert_eq!(d.cycle_window_seconds, 1.0);
        assert_eq!(d.wall_switch.brightness_step, 50);
    }
}
