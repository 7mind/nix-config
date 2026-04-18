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
#[path = "switch_model_tests.rs"]
mod tests;
