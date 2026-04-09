//! Declarative action rules. Each rule pairs a [`Trigger`] (an event
//! condition) with an [`Effect`] (a command to execute). Actions run in
//! parallel with room bindings and are the primary mechanism for
//! controlling smart plugs.
//!
//! Trigger/effect pairs are intentionally decoupled from the room/scene
//! model: a trigger fires on an event from any device in the catalog,
//! and the effect targets a specific device (currently plugs only; group
//! targets are a planned extension).
//!
//! ## Kill switch
//!
//! The `PowerBelow` trigger is stateful: it requires power to stay below
//! a threshold for a configurable holdoff duration before firing. The
//! controller evaluates pending kill switches on every [`Tick`] event
//! (periodic timer in the daemon). When the effect fires and turns the
//! plug off, the kill switch rearms on the next manual turn-on — no
//! explicit rearm step is needed.

use serde::{Deserialize, Serialize};

/// One declarative action rule. Validated at topology-build time
/// (trigger device exists, effect target is a plug, capability gates
/// pass).
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ActionRule {
    /// Stable human-readable name. Must be unique across all action
    /// rules. Used for logging and diagnostics.
    pub name: String,

    /// What event condition activates this rule.
    pub trigger: Trigger,

    /// What command to execute when the trigger fires.
    pub effect: Effect,
}

/// Event condition that activates an action rule. Tagged by `kind`.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Trigger {
    /// A tap button was pressed (Hue Tap or Sonoff orb switch).
    Tap {
        device: String,
        button: u8,
        /// `None` matches press/single taps. `Some("double")` matches
        /// double-taps only. Omit in config for standard single-tap.
        #[serde(default)]
        action: Option<String>,
    },

    /// A Hue dimmer wall switch "on" button was pressed.
    SwitchOn {
        device: String,
    },

    /// A Hue dimmer wall switch "off" button was pressed.
    SwitchOff {
        device: String,
    },

    /// A plug's real-time power reading stayed below `watts` for at
    /// least `for_seconds`. Requires the target plug to have the
    /// `"power"` capability.
    PowerBelow {
        device: String,
        watts: f64,
        for_seconds: u64,
    },

    /// Fires once per day at the specified local time (hour:minute).
    /// Evaluated on every `Tick` event (~5 s resolution).
    At {
        hour: u8,
        minute: u8,
    },
}

/// Command to execute when a trigger fires.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Effect {
    /// Toggle the target device: if ON → OFF, if OFF → ON.
    ///
    /// When `confirm_off_seconds` is set, turning OFF requires a
    /// double-tap: the first tap while ON starts a confirmation
    /// window, and only a second tap within that window actually
    /// turns the device off. Turning ON is always immediate.
    Toggle {
        target: String,
        #[serde(default)]
        confirm_off_seconds: Option<f64>,
    },

    /// Turn the target device ON unconditionally.
    TurnOn {
        target: String,
    },

    /// Turn the target device OFF unconditionally.
    TurnOff {
        target: String,
    },

    /// Turn off every light zone (room group). Used for scheduled
    /// "everything off" rules. The controller iterates all rooms and
    /// publishes state OFF to each group.
    TurnOffAllZones,
}

impl Trigger {
    /// The device friendly_name this trigger watches, if any.
    /// `At` triggers are time-based and have no device.
    pub fn device(&self) -> Option<&str> {
        match self {
            Self::Tap { device, .. }
            | Self::SwitchOn { device }
            | Self::SwitchOff { device }
            | Self::PowerBelow { device, .. } => Some(device),
            Self::At { .. } => None,
        }
    }
}

impl Effect {
    /// The device friendly_name this effect targets, if any.
    /// `TurnOffAllZones` has no single target.
    pub fn target(&self) -> Option<&str> {
        match self {
            Self::Toggle { target, .. }
            | Self::TurnOn { target }
            | Self::TurnOff { target } => Some(target),
            Self::TurnOffAllZones => None,
        }
    }

    /// For `Toggle` with `confirm_off_seconds`, the confirmation window.
    pub fn confirm_off_seconds(&self) -> Option<f64> {
        match self {
            Self::Toggle { confirm_off_seconds, .. } => *confirm_off_seconds,
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deserialize_tap_toggle_rule() {
        let json = r#"{
            "name": "printer-toggle",
            "trigger": { "kind": "tap", "device": "hue-ts-office", "button": 3 },
            "effect": { "kind": "toggle", "target": "z2m-p-printer" }
        }"#;
        let rule: ActionRule = serde_json::from_str(json).unwrap();
        assert_eq!(rule.name, "printer-toggle");
        assert_eq!(rule.trigger.device(), Some("hue-ts-office"));
        assert_eq!(rule.effect.target(), Some("z2m-p-printer"));
        match &rule.trigger {
            Trigger::Tap { button, .. } => assert_eq!(*button, 3),
            other => panic!("expected Tap, got {other:?}"),
        }
    }

    #[test]
    fn deserialize_switch_on_rule() {
        let json = r#"{
            "name": "lamp-on",
            "trigger": { "kind": "switch_on", "device": "hue-s-office" },
            "effect": { "kind": "turn_on", "target": "z2m-p-lamp" }
        }"#;
        let rule: ActionRule = serde_json::from_str(json).unwrap();
        match &rule.trigger {
            Trigger::SwitchOn { device } => assert_eq!(device, "hue-s-office"),
            other => panic!("expected SwitchOn, got {other:?}"),
        }
        match &rule.effect {
            Effect::TurnOn { target } => assert_eq!(target, "z2m-p-lamp"),
            other => panic!("expected TurnOn, got {other:?}"),
        }
    }

    #[test]
    fn deserialize_switch_off_rule() {
        let json = r#"{
            "name": "lamp-off",
            "trigger": { "kind": "switch_off", "device": "hue-s-office" },
            "effect": { "kind": "turn_off", "target": "z2m-p-lamp" }
        }"#;
        let rule: ActionRule = serde_json::from_str(json).unwrap();
        match &rule.trigger {
            Trigger::SwitchOff { device } => assert_eq!(device, "hue-s-office"),
            other => panic!("expected SwitchOff, got {other:?}"),
        }
    }

    #[test]
    fn deserialize_power_below_rule() {
        let json = r#"{
            "name": "printer-kill",
            "trigger": {
                "kind": "power_below",
                "device": "z2m-p-printer",
                "watts": 5.0,
                "for_seconds": 300
            },
            "effect": { "kind": "turn_off", "target": "z2m-p-printer" }
        }"#;
        let rule: ActionRule = serde_json::from_str(json).unwrap();
        match &rule.trigger {
            Trigger::PowerBelow { device, watts, for_seconds } => {
                assert_eq!(device, "z2m-p-printer");
                assert!((watts - 5.0).abs() < f64::EPSILON);
                assert_eq!(*for_seconds, 300);
            }
            other => panic!("expected PowerBelow, got {other:?}"),
        }
    }

    #[test]
    fn unknown_trigger_kind_rejected() {
        let json = r#"{
            "name": "bad",
            "trigger": { "kind": "explosion", "device": "x" },
            "effect": { "kind": "toggle", "target": "y" }
        }"#;
        let result: Result<ActionRule, _> = serde_json::from_str(json);
        assert!(result.is_err());
    }

    #[test]
    fn unknown_effect_kind_rejected() {
        let json = r#"{
            "name": "bad",
            "trigger": { "kind": "tap", "device": "x", "button": 1 },
            "effect": { "kind": "explode", "target": "y" }
        }"#;
        let result: Result<ActionRule, _> = serde_json::from_str(json);
        assert!(result.is_err());
    }

    #[test]
    fn unknown_field_in_trigger_rejected() {
        let json = r#"{
            "name": "bad",
            "trigger": { "kind": "tap", "device": "x", "button": 1, "ghost": true },
            "effect": { "kind": "toggle", "target": "y" }
        }"#;
        let result: Result<ActionRule, _> = serde_json::from_str(json);
        assert!(result.is_err());
    }

    #[test]
    fn trigger_device_accessor() {
        let t = Trigger::PowerBelow {
            device: "z2m-p-foo".into(),
            watts: 1.0,
            for_seconds: 60,
        };
        assert_eq!(t.device(), Some("z2m-p-foo"));
    }

    #[test]
    fn effect_target_accessor() {
        let e = Effect::Toggle { target: "z2m-p-bar".into(), confirm_off_seconds: None };
        assert_eq!(e.target(), Some("z2m-p-bar"));

        assert_eq!(Effect::TurnOffAllZones.target(), None);
    }

    #[test]
    fn deserialize_toggle_with_confirm_off() {
        let json = r#"{
            "name": "ws-toggle",
            "trigger": { "kind": "tap", "device": "sonoff-ts-ws", "button": 1 },
            "effect": { "kind": "toggle", "target": "sonoff-p-ws", "confirm_off_seconds": 1.0 }
        }"#;
        let rule: ActionRule = serde_json::from_str(json).unwrap();
        assert_eq!(rule.effect.confirm_off_seconds(), Some(1.0));
    }

    #[test]
    fn deserialize_toggle_without_confirm_off() {
        let json = r#"{
            "name": "printer-toggle",
            "trigger": { "kind": "tap", "device": "hue-ts-office", "button": 3 },
            "effect": { "kind": "toggle", "target": "z2m-p-printer" }
        }"#;
        let rule: ActionRule = serde_json::from_str(json).unwrap();
        assert_eq!(rule.effect.confirm_off_seconds(), None);
    }
}
