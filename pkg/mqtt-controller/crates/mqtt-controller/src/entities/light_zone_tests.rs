//! Tests for `light_zone`. Split out so `light_zone.rs` stays focused on
//! production code. See `light_zone.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;
use crate::tass::{ActualFreshness, TargetPhase};

#[test]
fn default_zone_is_off_and_unknown() {
    let z = LightZoneEntity::default();
    assert!(!z.is_on());
    assert!(!z.target_is_on());
    assert!(!z.actual_is_on());
    assert!(!z.is_motion_owned());
    assert_eq!(z.cycle_idx(), 0);
    assert!(z.last_press_at.is_none());
    assert!(z.last_off_at.is_none());
    assert_eq!(z.target.phase(), TargetPhase::Unset);
    assert_eq!(z.actual.freshness(), ActualFreshness::Unknown);
}

#[test]
fn is_on_from_target() {
    let mut z = LightZoneEntity::default();
    let ts = Instant::now();

    z.target
        .set_and_command(LightZoneTarget::On { scene_id: 1, cycle_idx: 0 }, Owner::User, ts);
    assert!(z.is_on());
    assert!(z.target_is_on());
    assert!(!z.actual_is_on()); // actual still unknown
}

#[test]
fn is_on_from_actual() {
    let mut z = LightZoneEntity::default();
    let ts = Instant::now();

    z.actual.update(LightZoneActual::On, ts);
    assert!(z.is_on());
    assert!(!z.target_is_on()); // target still unset
    assert!(z.actual_is_on());
}

#[test]
fn not_on_when_target_off_and_actual_off() {
    let mut z = LightZoneEntity::default();
    let ts = Instant::now();

    z.target.set_and_command(LightZoneTarget::Off, Owner::System, ts);
    z.actual.update(LightZoneActual::Off, ts);
    assert!(!z.is_on());
}

#[test]
fn cycle_idx_from_target() {
    let mut z = LightZoneEntity::default();
    let ts = Instant::now();

    assert_eq!(z.cycle_idx(), 0); // default

    z.target
        .set_and_command(LightZoneTarget::On { scene_id: 2, cycle_idx: 3 }, Owner::User, ts);
    assert_eq!(z.cycle_idx(), 3);

    z.target.set_and_command(LightZoneTarget::Off, Owner::User, ts);
    assert_eq!(z.cycle_idx(), 0); // Off has no cycle
}

#[test]
fn motion_ownership() {
    let mut z = LightZoneEntity::default();
    let ts = Instant::now();

    assert!(!z.is_motion_owned());

    z.target
        .set_and_command(LightZoneTarget::On { scene_id: 1, cycle_idx: 0 }, Owner::Motion, ts);
    assert!(z.is_motion_owned());

    // User press overrides motion
    z.target
        .set_and_command(LightZoneTarget::On { scene_id: 2, cycle_idx: 1 }, Owner::User, ts);
    assert!(!z.is_motion_owned());
}
