//! Plug TASS entity. One per smart plug device.

use std::collections::BTreeMap;
use std::time::Instant;

use crate::tass::{TassActual, TassTarget};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlugTarget {
    On,
    Off,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PlugActual {
    pub on: bool,
    pub power: Option<f64>,
}

/// Kill switch rule state machine.
///
/// Replaces the three separate BTreeMaps (armed, suppressed, idle_since)
/// on the old KillSwitchEvaluator with a single enum per rule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KillSwitchRuleState {
    /// Rule not yet armed. Power must exceed threshold once to arm.
    Inactive,
    /// Power seen above threshold at least once since plug turned on.
    Armed,
    /// Power below threshold, holdoff clock running.
    Idle { since: Instant },
    /// Fired and suppressed. Cleared when power recovers above threshold.
    Suppressed,
}

/// A smart plug with kill switch automation.
#[derive(Debug, Clone)]
pub struct PlugEntity {
    pub target: TassTarget<PlugTarget>,
    pub actual: TassActual<PlugActual>,
    /// Kill switch state per rule name.
    pub kill_switch_rules: BTreeMap<String, KillSwitchRuleState>,
}

impl Default for PlugEntity {
    fn default() -> Self {
        Self {
            target: TassTarget::new(),
            actual: TassActual::new(),
            kill_switch_rules: BTreeMap::new(),
        }
    }
}

impl PlugEntity {
    /// True if the plug is considered "on" for business logic.
    /// Optimistic: true if target says On OR actual reports On.
    pub fn is_on(&self) -> bool {
        self.target
            .value()
            .is_some_and(|t| *t == PlugTarget::On)
            || self.actual.value().is_some_and(|a| a.on)
    }

    /// Most recent power reading (from actual state).
    pub fn power(&self) -> Option<f64> {
        self.actual.value().and_then(|a| a.power)
    }

    /// Clear kill switch tracking on off-transition. Resets Armed/Idle
    /// to Inactive but preserves Suppressed (matches old on_plug_off
    /// behavior — suppression persists across off/on cycles until power
    /// recovers above threshold).
    pub fn on_off_clear_kill_switches(&mut self) {
        for state in self.kill_switch_rules.values_mut() {
            match state {
                KillSwitchRuleState::Suppressed => {} // preserve
                _ => *state = KillSwitchRuleState::Inactive,
            }
        }
    }

    /// Suppress all kill switch rules. Called when any rule fires.
    pub fn suppress_all_kill_switches(&mut self) {
        for state in self.kill_switch_rules.values_mut() {
            *state = KillSwitchRuleState::Suppressed;
        }
    }
}

#[cfg(test)]
#[path = "plug_tests.rs"]
mod tests;
