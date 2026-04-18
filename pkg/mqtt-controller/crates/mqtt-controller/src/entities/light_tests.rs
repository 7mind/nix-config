//! Tests for `light`. Split out so `light.rs` stays focused on
//! production code. See `light.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;
use crate::tass::ActualFreshness;
use std::time::Instant;

#[test]
fn default_light_is_off_unknown() {
    let l = LightEntity::default();
    assert!(!l.is_on());
    assert_eq!(l.actual.freshness(), ActualFreshness::Unknown);
}

#[test]
fn update_sets_actual_fresh() {
    let mut l = LightEntity::default();
    let ts = Instant::now();
    l.actual.update(
        LightActual {
            on: true,
            brightness: Some(200),
            color_temp: Some(350),
            color_xy: None,
        },
        ts,
    );
    assert!(l.is_on());
    assert_eq!(l.actual.freshness(), ActualFreshness::Fresh);
    assert_eq!(l.actual.value().unwrap().brightness, Some(200));
}
