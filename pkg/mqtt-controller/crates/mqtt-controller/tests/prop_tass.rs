//! Property-based tests for TASS state machine invariants.
//!
//! These tests generate random sequences of operations on TassTarget
//! and TassActual and verify that structural invariants hold after
//! every operation.

use std::time::{Duration, Instant};

use mqtt_controller::tass::*;
use proptest::prelude::*;

/// Operations that can be applied to a TassTarget<u8>.
#[derive(Debug, Clone)]
enum TargetOp {
    Set { value: u8, owner: Owner },
    SetAndCommand { value: u8, owner: Owner },
    Command,
    Confirm,
    MarkStale,
}

/// Operations that can be applied to a TassActual<u8>.
#[derive(Debug, Clone)]
enum ActualOp {
    Update { value: u8 },
    MarkStale,
}

fn arb_owner() -> impl Strategy<Value = Owner> {
    prop_oneof![
        Just(Owner::User),
        Just(Owner::Motion),
        Just(Owner::Schedule),
        Just(Owner::WebUI),
        Just(Owner::System),
        Just(Owner::Rule),
    ]
}

fn arb_target_op() -> impl Strategy<Value = TargetOp> {
    prop_oneof![
        (any::<u8>(), arb_owner()).prop_map(|(v, o)| TargetOp::Set { value: v, owner: o }),
        (any::<u8>(), arb_owner()).prop_map(|(v, o)| TargetOp::SetAndCommand { value: v, owner: o }),
        Just(TargetOp::Command),
        Just(TargetOp::Confirm),
        Just(TargetOp::MarkStale),
    ]
}

fn arb_actual_op() -> impl Strategy<Value = ActualOp> {
    prop_oneof![
        any::<u8>().prop_map(|v| ActualOp::Update { value: v }),
        Just(ActualOp::MarkStale),
    ]
}

/// Apply a target operation, returning whether it should succeed.
fn apply_target_op(target: &mut TassTarget<u8>, op: &TargetOp, ts: Instant) -> bool {
    match op {
        TargetOp::Set { value, owner } => {
            target.set(*value, *owner, ts);
            true
        }
        TargetOp::SetAndCommand { value, owner } => {
            target.set_and_command(*value, *owner, ts);
            true
        }
        TargetOp::Command => {
            if target.phase() == TargetPhase::Pending {
                target.command(ts);
                true
            } else {
                false // skip, would panic
            }
        }
        TargetOp::Confirm => {
            if matches!(
                target.phase(),
                TargetPhase::Commanded | TargetPhase::Stale | TargetPhase::Confirmed
            ) {
                target.confirm(ts);
                true
            } else {
                false
            }
        }
        TargetOp::MarkStale => {
            target.mark_stale();
            true
        }
    }
}

fn apply_actual_op(actual: &mut TassActual<u8>, op: &ActualOp, ts: Instant) {
    match op {
        ActualOp::Update { value } => actual.update(*value, ts),
        ActualOp::MarkStale => actual.mark_stale(),
    }
}

// ---- Target invariants ----

fn assert_target_invariants(target: &TassTarget<u8>) {
    match target.phase() {
        TargetPhase::Unset => {
            assert!(target.value().is_none(), "Unset target must have no value");
            assert!(target.owner().is_none(), "Unset target must have no owner");
            assert!(target.since().is_none(), "Unset target must have no timestamp");
        }
        TargetPhase::Pending | TargetPhase::Commanded | TargetPhase::Stale | TargetPhase::Confirmed => {
            assert!(target.value().is_some(), "{:?} target must have a value", target.phase());
            assert!(target.owner().is_some(), "{:?} target must have an owner", target.phase());
            assert!(target.since().is_some(), "{:?} target must have a timestamp", target.phase());
        }
    }
    assert_eq!(target.is_unset(), target.phase() == TargetPhase::Unset);
}

// ---- Actual invariants ----

fn assert_actual_invariants(actual: &TassActual<u8>) {
    match actual.freshness() {
        ActualFreshness::Unknown => {
            assert!(actual.value().is_none(), "Unknown actual must have no value");
            assert!(actual.since().is_none(), "Unknown actual must have no timestamp");
            assert!(!actual.is_known(), "Unknown must not be known");
        }
        ActualFreshness::Fresh | ActualFreshness::Stale => {
            assert!(actual.value().is_some(), "{:?} actual must have a value", actual.freshness());
            assert!(actual.since().is_some(), "{:?} actual must have a timestamp", actual.freshness());
            assert!(actual.is_known(), "{:?} must be known", actual.freshness());
        }
    }
}

proptest! {
    /// Random sequences of target operations preserve invariants.
    #[test]
    fn target_invariants_hold_under_random_ops(
        ops in prop::collection::vec(arb_target_op(), 1..50)
    ) {
        let mut target: TassTarget<u8> = TassTarget::new();
        assert_target_invariants(&target);

        let base = Instant::now();
        for (i, op) in ops.iter().enumerate() {
            let ts = base + Duration::from_millis(i as u64);
            apply_target_op(&mut target, op, ts);
            assert_target_invariants(&target);
        }
    }

    /// Random sequences of actual operations preserve invariants.
    #[test]
    fn actual_invariants_hold_under_random_ops(
        ops in prop::collection::vec(arb_actual_op(), 1..50)
    ) {
        let mut actual: TassActual<u8> = TassActual::new();
        assert_actual_invariants(&actual);

        let base = Instant::now();
        for (i, op) in ops.iter().enumerate() {
            let ts = base + Duration::from_millis(i as u64);
            apply_actual_op(&mut actual, op, ts);
            assert_actual_invariants(&actual);
        }
    }

    /// Target phase never goes backward to Unset after being set.
    #[test]
    fn target_phase_never_returns_to_unset(
        ops in prop::collection::vec(arb_target_op(), 1..50)
    ) {
        let mut target: TassTarget<u8> = TassTarget::new();
        let mut was_set = false;

        let base = Instant::now();
        for (i, op) in ops.iter().enumerate() {
            let ts = base + Duration::from_millis(i as u64);
            apply_target_op(&mut target, op, ts);

            if !target.is_unset() {
                was_set = true;
            }
            if was_set {
                prop_assert!(!target.is_unset(),
                    "Target phase returned to Unset after being set (op {:?})", op);
            }
        }
    }

    /// Actual freshness can only transition Unknown→Fresh or Fresh→Stale→Fresh.
    /// It never goes from Stale→Unknown or Fresh→Unknown.
    #[test]
    fn actual_freshness_never_returns_to_unknown(
        ops in prop::collection::vec(arb_actual_op(), 1..50)
    ) {
        let mut actual: TassActual<u8> = TassActual::new();
        let mut was_known = false;

        let base = Instant::now();
        for (i, op) in ops.iter().enumerate() {
            let ts = base + Duration::from_millis(i as u64);
            apply_actual_op(&mut actual, op, ts);

            if actual.is_known() {
                was_known = true;
            }
            if was_known {
                prop_assert!(actual.freshness() != ActualFreshness::Unknown,
                    "Actual freshness returned to Unknown after being known");
            }
        }
    }

    /// SetAndCommand always results in Commanded phase.
    #[test]
    fn set_and_command_always_commanded(value: u8, owner_idx in 0..6u8) {
        let owners = [Owner::User, Owner::Motion, Owner::Schedule, Owner::WebUI, Owner::System, Owner::Rule];
        let owner = owners[owner_idx as usize];
        let mut target: TassTarget<u8> = TassTarget::new();
        let ts = Instant::now();

        target.set_and_command(value, owner, ts);

        prop_assert_eq!(target.phase(), TargetPhase::Commanded);
        prop_assert_eq!(target.value(), Some(&value));
        prop_assert_eq!(target.owner(), Some(owner));
    }

    /// Update always results in Fresh freshness.
    #[test]
    fn update_always_fresh(value: u8) {
        let mut actual: TassActual<u8> = TassActual::new();
        let ts = Instant::now();

        // Start from any state
        actual.mark_stale(); // no-op from Unknown
        actual.update(value, ts);
        prop_assert_eq!(actual.freshness(), ActualFreshness::Fresh);

        actual.mark_stale();
        actual.update(value.wrapping_add(1), ts + Duration::from_millis(1));
        prop_assert_eq!(actual.freshness(), ActualFreshness::Fresh);
    }

    /// Confirm preserves the target value and owner.
    #[test]
    fn confirm_preserves_value_and_owner(value: u8, owner_idx in 0..6u8) {
        let owners = [Owner::User, Owner::Motion, Owner::Schedule, Owner::WebUI, Owner::System, Owner::Rule];
        let owner = owners[owner_idx as usize];
        let mut target: TassTarget<u8> = TassTarget::new();
        let ts = Instant::now();

        target.set_and_command(value, owner, ts);
        target.confirm(ts);

        prop_assert_eq!(target.value(), Some(&value));
        prop_assert_eq!(target.owner(), Some(owner));
        prop_assert_eq!(target.phase(), TargetPhase::Confirmed);
    }
}
