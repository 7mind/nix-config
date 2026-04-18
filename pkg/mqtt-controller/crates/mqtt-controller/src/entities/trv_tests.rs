//! Tests for `trv`. Split out so `trv.rs` stays focused on
//! production code. See `trv.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;
use crate::tass::Owner;

#[test]
fn running_state_parse() {
    assert_eq!(HeatingRunningState::parse("idle"), Some(HeatingRunningState::Idle));
    assert_eq!(HeatingRunningState::parse("heat"), Some(HeatingRunningState::Heat));
    assert_eq!(HeatingRunningState::parse("cool"), None);
}

#[test]
fn trv_inhibition() {
    let now = Instant::now();
    let mut trv = TrvEntity::default();

    trv.target.set_and_command(
        TrvTarget::Inhibited {
            until: now + Duration::from_secs(60),
        },
        Owner::Rule,
        now,
    );
    assert!(trv.is_inhibited(now));
    assert!(!trv.is_inhibited(now + Duration::from_secs(61)));
}

#[test]
fn trv_forced_open() {
    let now = Instant::now();
    let mut trv = TrvEntity::default();

    trv.target.set_and_command(
        TrvTarget::ForcedOpen {
            reason: ForceOpenReason::PressureGroup,
        },
        Owner::Rule,
        now,
    );
    assert!(trv.is_forced_open());
    assert!(!trv.is_inhibited(now));
}

#[test]
fn trv_demand_suppressed_during_release() {
    let now = Instant::now();
    let mut trv = TrvEntity::default();

    // Simulate: normal setpoint, has demand
    let mut actual = TrvActual::default();
    actual.running_state = HeatingRunningState::Heat;
    actual.running_state_seen = true;
    actual.pi_heating_demand = Some(50);
    trv.actual.update(actual, now);

    // Confirmed setpoint → demand counts
    trv.target
        .set_and_command(TrvTarget::Setpoint(21.0), Owner::Schedule, now);
    trv.target.confirm(now);
    assert!(trv.has_effective_demand(now, 5, 80));

    // New setpoint commanded (release from force) → demand suppressed
    trv.target
        .set_and_command(TrvTarget::Setpoint(18.0), Owner::Schedule, now);
    assert!(!trv.has_effective_demand(now, 5, 80));
    assert!(trv.has_raw_demand(5, 80)); // raw demand still present
}
