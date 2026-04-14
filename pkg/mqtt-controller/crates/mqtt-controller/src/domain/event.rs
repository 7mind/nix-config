//! Events flowing into the controller. Every MQTT message that the
//! controller cares about is parsed into one of these variants by the
//! [`crate::mqtt`] bridge before reaching the state machine.

use std::time::Instant;

use serde::{Deserialize, Serialize};

/// One discrete input event from the outside world. Wraps everything in
/// a single sum type so the controller's `handle_event` is one big match.
#[derive(Debug, Clone)]
pub enum Event {
    /// A Hue dimmer wall switch fired one of its action codes.
    SwitchAction {
        device: String,
        action: SwitchAction,
        ts: Instant,
    },

    /// A tap button was pressed (Hue Tap or Sonoff orb switch).
    TapAction {
        device: String,
        button: u8,
        /// `None` for press/single, `Some("double")` for double-tap.
        action: Option<String>,
        ts: Instant,
    },

    /// A Hue motion sensor reported an occupancy update.
    Occupancy {
        sensor: String,
        occupied: bool,
        illuminance: Option<u32>,
        ts: Instant,
    },

    /// z2m published a state update for a group we subscribe to. The
    /// controller uses this as ground truth for `physically_on` and
    /// reconciles its internal state machine accordingly.
    GroupState {
        group: String,
        on: bool,
        ts: Instant,
    },

    /// z2m published a state update for a smart plug we subscribe to.
    /// Carries the on/off state and, if the plug supports power
    /// monitoring, the real-time power reading in watts.
    PlugState {
        device: String,
        on: bool,
        /// Real-time power in watts. `None` if the plug doesn't expose
        /// power monitoring or the field was absent from the payload.
        power: Option<f64>,
        ts: Instant,
    },

    /// A Z-Wave plug's meter reported a power update without an
    /// accompanying on/off state change. Z-Wave JS UI publishes state
    /// and power on separate MQTT topics, so power-only updates arrive
    /// independently. The controller updates the plug's power reading
    /// without touching its on/off tracking.
    PlugPowerUpdate {
        device: String,
        /// Real-time power in watts.
        watts: f64,
        ts: Instant,
    },

    /// A TRV (thermostatic radiator valve) reported a state update.
    /// Fields are optional because z2m may publish partial updates.
    TrvState {
        device: String,
        local_temperature: Option<f64>,
        pi_heating_demand: Option<u8>,
        /// `"idle"` or `"heat"`.
        running_state: Option<String>,
        occupied_heating_setpoint: Option<f64>,
        /// `"schedule"`, `"manual"`, or `"pause"`.
        operating_mode: Option<String>,
        /// Battery percentage (0-100).
        battery: Option<u8>,
        ts: Instant,
    },

    /// A wall thermostat (used as relay) reported a state update.
    WallThermostatState {
        device: String,
        /// Relay on/off from the `"state"` JSON field.
        relay_on: Option<bool>,
        local_temperature: Option<f64>,
        /// `"schedule"`, `"manual"`, or `"pause"`.
        operating_mode: Option<String>,
        ts: Instant,
    },

    /// Periodic tick event fired by the daemon's timer. The controller
    /// uses this to evaluate time-dependent action triggers (kill
    /// switch holdoff deadlines) and heating schedule/relay decisions.
    Tick {
        ts: Instant,
    },
}

/// One of the action codes a Hue dimmer publishes on
/// `zigbee2mqtt/<friendly_name>/action`. Mirrors the bento switch
/// dispatch cases one-to-one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SwitchAction {
    OnPressRelease,
    OffPressRelease,
    UpPressRelease,
    DownPressRelease,
    UpHold,
    UpHoldRelease,
    DownHold,
    DownHoldRelease,
}

impl SwitchAction {
    /// Parse the raw `action` payload string z2m publishes for Hue dimmers.
    /// Returns `None` for unknown / unsupported actions (e.g. long-press
    /// scene buttons we don't bind).
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "on_press_release" => Self::OnPressRelease,
            "off_press_release" => Self::OffPressRelease,
            "up_press_release" => Self::UpPressRelease,
            "down_press_release" => Self::DownPressRelease,
            "up_hold" => Self::UpHold,
            "up_hold_release" => Self::UpHoldRelease,
            "down_hold" => Self::DownHold,
            "down_hold_release" => Self::DownHoldRelease,
            _ => return None,
        })
    }
}

/// Parsed tap action: button number + optional action qualifier.
///
/// Hue taps send `press_N`, Sonoff orb switches send `single_button_N`
/// and `double_button_N`. The action qualifier distinguishes tap types:
///   - `None` = standard press / single tap (the default)
///   - `Some("double")` = double tap
pub struct TapActionParsed {
    pub button: u8,
    /// `None` for `press_N` and `single_button_N`; `Some("double")` for
    /// `double_button_N`. Extensible for future tap types (long press, etc.).
    pub action: Option<String>,
}

/// Parse a tap action payload into a button number + action qualifier.
/// Returns `None` for unrecognized payloads.
pub fn parse_tap_action(s: &str) -> Option<TapActionParsed> {
    // Hue Tap: "press_1" .. "press_4"
    if let Some(n) = s.strip_prefix("press_") {
        return n.parse::<u8>().ok().map(|button| TapActionParsed { button, action: None });
    }
    // Sonoff single: "single_button_1" .. "single_button_4"
    if let Some(n) = s.strip_prefix("single_button_") {
        return n.parse::<u8>().ok().map(|button| TapActionParsed { button, action: None });
    }
    // Sonoff double: "double_button_1" .. "double_button_4"
    if let Some(n) = s.strip_prefix("double_button_") {
        return n.parse::<u8>().ok().map(|button| TapActionParsed {
            button,
            action: Some("double".to_string()),
        });
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn switch_action_parse_known() {
        assert_eq!(
            SwitchAction::parse("on_press_release"),
            Some(SwitchAction::OnPressRelease)
        );
        assert_eq!(
            SwitchAction::parse("down_hold"),
            Some(SwitchAction::DownHold)
        );
    }

    #[test]
    fn switch_action_parse_unknown_returns_none() {
        assert_eq!(SwitchAction::parse("scene_press"), None);
        assert_eq!(SwitchAction::parse(""), None);
    }

    #[test]
    fn tap_action_parse_hue_press() {
        let p = parse_tap_action("press_1").unwrap();
        assert_eq!(p.button, 1);
        assert!(p.action.is_none());

        let p = parse_tap_action("press_4").unwrap();
        assert_eq!(p.button, 4);
        assert!(p.action.is_none());
    }

    #[test]
    fn tap_action_parse_sonoff_single() {
        let p = parse_tap_action("single_button_1").unwrap();
        assert_eq!(p.button, 1);
        assert!(p.action.is_none());
    }

    #[test]
    fn tap_action_parse_sonoff_double() {
        let p = parse_tap_action("double_button_2").unwrap();
        assert_eq!(p.button, 2);
        assert_eq!(p.action.as_deref(), Some("double"));
    }

    #[test]
    fn tap_action_parse_unknown_returns_none() {
        assert!(parse_tap_action("hold_1").is_none());
        assert!(parse_tap_action("press_x").is_none());
        assert!(parse_tap_action("triple_button_1").is_none());
    }
}
