//! Tests for `time`. Split out so `time.rs` stays focused on
//! production code. See `time.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;

#[test]
fn fake_clock_advances() {
    let clk = FakeClock::new(12);
    let t0 = clk.now();
    clk.advance(Duration::from_millis(500));
    let t1 = clk.now();
    assert_eq!(t1.duration_since(t0), Duration::from_millis(500));
}

#[test]
fn fake_clock_set_hour() {
    let clk = FakeClock::new(12);
    assert_eq!(clk.local_hour(), 12);
    clk.set_hour(23);
    assert_eq!(clk.local_hour(), 23);
}
