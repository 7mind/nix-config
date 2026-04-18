//! Tests for `plug`. Split out so `plug.rs` stays focused on
//! production code. See `plug.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

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
