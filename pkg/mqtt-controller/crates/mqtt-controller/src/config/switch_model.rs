//! Switch model descriptors. Each model defines the buttons a switch has
//! and how raw z2m action strings map to semantic `(button, gesture)` pairs.
//!
//! This is pure data — adding a new switch type means adding a model
//! descriptor to the JSON config, no Rust code changes needed.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// The gesture a button event represents. Parsed from z2m action strings
/// via the model's `z2m_action_map`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Gesture {
    /// Button pressed (and released). The primary interaction.
    Press,
    /// Button held down (continuous — e.g. brightness ramp).
    Hold,
    /// Button released after a hold.
    HoldRelease,
    /// Hardware double-tap reported by the device firmware (e.g. Sonoff).
    DoubleTap,
    /// Software-detected double-tap: two presses within a configurable
    /// window. The controller synthesizes this from buffered press events.
    SoftDoubleTap,
}

/// One entry in a model's z2m action map: which button and gesture a raw
/// z2m action string corresponds to.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ActionMapping {
    pub button: String,
    pub gesture: Gesture,
}

/// A switch model descriptor. Defines the hardware's button layout and
/// how z2m action strings are translated into semantic events.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SwitchModel {
    /// The buttons this model has (e.g. `["on", "off", "up", "down"]`
    /// for a Hue dimmer, `["1", "2", "3", "4"]` for a Hue Tap).
    pub buttons: Vec<String>,

    /// Maps raw z2m action payload strings to `(button, gesture)` pairs.
    /// E.g. `"on_press_release" → { button: "on", gesture: "press" }`.
    pub z2m_action_map: BTreeMap<String, ActionMapping>,
}

impl SwitchModel {
    /// Look up a raw z2m action string and return the semantic mapping.
    pub fn resolve(&self, z2m_action: &str) -> Option<&ActionMapping> {
        self.z2m_action_map.get(z2m_action)
    }

    /// True if any button in this model has both `press` and `double_tap`
    /// gestures mapped. Used to activate double-tap suppression for the
    /// Sonoff firmware quirk.
    pub fn has_hardware_double_tap(&self) -> bool {
        for button in &self.buttons {
            let has_press = self.z2m_action_map.values().any(|m| {
                m.button == *button && m.gesture == Gesture::Press
            });
            let has_double = self.z2m_action_map.values().any(|m| {
                m.button == *button && m.gesture == Gesture::DoubleTap
            });
            if has_press && has_double {
                return true;
            }
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deserialize_hue_dimmer_model() {
        let json = r#"{
            "buttons": ["on", "off", "up", "down"],
            "z2m_action_map": {
                "on_press_release": { "button": "on", "gesture": "press" },
                "off_press_release": { "button": "off", "gesture": "press" },
                "up_press_release": { "button": "up", "gesture": "press" },
                "up_hold": { "button": "up", "gesture": "hold" },
                "up_hold_release": { "button": "up", "gesture": "hold_release" },
                "down_press_release": { "button": "down", "gesture": "press" },
                "down_hold": { "button": "down", "gesture": "hold" },
                "down_hold_release": { "button": "down", "gesture": "hold_release" }
            }
        }"#;
        let model: SwitchModel = serde_json::from_str(json).unwrap();
        assert_eq!(model.buttons.len(), 4);
        let mapping = model.resolve("on_press_release").unwrap();
        assert_eq!(mapping.button, "on");
        assert_eq!(mapping.gesture, Gesture::Press);
        assert!(!model.has_hardware_double_tap());
    }

    #[test]
    fn deserialize_sonoff_orb_model() {
        let json = r#"{
            "buttons": ["1", "2", "3", "4"],
            "z2m_action_map": {
                "single_button_1": { "button": "1", "gesture": "press" },
                "single_button_2": { "button": "2", "gesture": "press" },
                "double_button_1": { "button": "1", "gesture": "double_tap" },
                "double_button_2": { "button": "2", "gesture": "double_tap" }
            }
        }"#;
        let model: SwitchModel = serde_json::from_str(json).unwrap();
        assert!(model.has_hardware_double_tap());
        let mapping = model.resolve("double_button_1").unwrap();
        assert_eq!(mapping.button, "1");
        assert_eq!(mapping.gesture, Gesture::DoubleTap);
    }

    #[test]
    fn unknown_action_returns_none() {
        let json = r#"{
            "buttons": ["1"],
            "z2m_action_map": {
                "press_1": { "button": "1", "gesture": "press" }
            }
        }"#;
        let model: SwitchModel = serde_json::from_str(json).unwrap();
        assert!(model.resolve("unknown_action").is_none());
    }

    #[test]
    fn gesture_roundtrip() {
        for gesture in [Gesture::Press, Gesture::Hold, Gesture::HoldRelease, Gesture::DoubleTap, Gesture::SoftDoubleTap] {
            let json = serde_json::to_string(&gesture).unwrap();
            let back: Gesture = serde_json::from_str(&json).unwrap();
            assert_eq!(gesture, back);
        }
    }
}
