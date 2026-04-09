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

    /// A Hue Tap button was pressed (each button is a distinct event).
    TapAction {
        device: String,
        button: u8,
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

    /// Periodic tick event fired by the daemon's timer. The controller
    /// uses this to evaluate time-dependent action triggers (kill
    /// switch holdoff deadlines).
    Tick {
        ts: Instant,
    },
}

/// One of the action codes a Hue dimmer publishes on
/// `zigbee2mqtt/<friendly_name>/action`. Mirrors the bento switch
/// dispatch cases one-to-one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
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

/// Parse a tap action payload (`"press_1".."press_4"`) into a button
/// number. Returns `None` for anything else.
pub fn parse_tap_action(s: &str) -> Option<u8> {
    s.strip_prefix("press_").and_then(|n| n.parse::<u8>().ok())
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
    fn tap_action_parse() {
        assert_eq!(parse_tap_action("press_1"), Some(1));
        assert_eq!(parse_tap_action("press_4"), Some(4));
        assert_eq!(parse_tap_action("press_42"), Some(42));
        assert_eq!(parse_tap_action("press_x"), None);
        assert_eq!(parse_tap_action("hold_1"), None);
    }
}
