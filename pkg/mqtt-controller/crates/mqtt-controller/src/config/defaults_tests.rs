//! Tests for `defaults`. Split out so `defaults.rs` stays focused on
//! production code. See `defaults.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;

#[test]
fn empty_defaults_round_trip() {
    let d: Defaults = serde_json::from_str("{}").unwrap();
    assert_eq!(d.cycle_window_seconds, 1.0);
    assert_eq!(d.double_tap_suppression_seconds, 2.0);
    assert_eq!(d.soft_double_tap_window_seconds, 0.8);
}

#[test]
fn override_cycle_window() {
    let d: Defaults = serde_json::from_str(
        r#"{ "cycle_window_seconds": 0.5 }"#,
    )
    .unwrap();
    assert_eq!(d.cycle_window_seconds, 0.5);
    assert_eq!(d.soft_double_tap_window_seconds, 0.8);
}
