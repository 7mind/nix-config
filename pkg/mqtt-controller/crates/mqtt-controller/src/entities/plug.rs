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
mod tests {
    use super::*;
    use crate::tass::{ActualFreshness, Owner, TargetPhase};

    #[test]
    fn default_plug_is_off_and_unknown() {
        let p = PlugEntity::default();
        assert!(!p.is_on());
        assert!(p.power().is_none());
        assert!(p.kill_switch_rules.is_empty());
        assert_eq!(p.target.phase(), TargetPhase::Unset);
        assert_eq!(p.actual.freshness(), ActualFreshness::Unknown);
    }

    #[test]
    fn is_on_from_target() {
        let mut p = PlugEntity::default();
        let ts = Instant::now();
        p.target.set_and_command(PlugTarget::On, Owner::User, ts);
        assert!(p.is_on());
    }

    #[test]
    fn is_on_from_actual() {
        let mut p = PlugEntity::default();
        let ts = Instant::now();
        p.actual.update(PlugActual { on: true, power: Some(100.0) }, ts);
        assert!(p.is_on());
    }

    #[test]
    fn power_from_actual() {
        let mut p = PlugEntity::default();
        let ts = Instant::now();
        p.actual.update(PlugActual { on: true, power: Some(42.5) }, ts);
        assert_eq!(p.power(), Some(42.5));
    }

    #[test]
    fn kill_switch_clear_preserves_suppressed() {
        let mut p = PlugEntity::default();
        let ts = Instant::now();
        p.kill_switch_rules.insert("r1".into(), KillSwitchRuleState::Armed);
        p.kill_switch_rules.insert("r2".into(), KillSwitchRuleState::Suppressed);
        p.kill_switch_rules.insert("r3".into(), KillSwitchRuleState::Idle { since: ts });

        p.on_off_clear_kill_switches();

        assert_eq!(p.kill_switch_rules["r1"], KillSwitchRuleState::Inactive);
        assert_eq!(p.kill_switch_rules["r2"], KillSwitchRuleState::Suppressed); // preserved
        assert_eq!(p.kill_switch_rules["r3"], KillSwitchRuleState::Inactive);
    }

    #[test]
    fn kill_switch_suppress_all() {
        let mut p = PlugEntity::default();
        let ts = Instant::now();
        p.kill_switch_rules.insert("r1".into(), KillSwitchRuleState::Armed);
        p.kill_switch_rules.insert("r2".into(), KillSwitchRuleState::Idle { since: ts });

        p.suppress_all_kill_switches();

        assert_eq!(p.kill_switch_rules["r1"], KillSwitchRuleState::Suppressed);
        assert_eq!(p.kill_switch_rules["r2"], KillSwitchRuleState::Suppressed);
    }

    #[test]
    fn on_off_clear_preserves_suppressed_resets_armed() {
        let mut p = PlugEntity::default();
        p.kill_switch_rules.insert("r1".into(), KillSwitchRuleState::Suppressed);
        p.kill_switch_rules.insert("r2".into(), KillSwitchRuleState::Armed);

        p.on_off_clear_kill_switches();

        assert_eq!(p.kill_switch_rules["r1"], KillSwitchRuleState::Suppressed); // preserved
        assert_eq!(p.kill_switch_rules["r2"], KillSwitchRuleState::Inactive);
    }
}
