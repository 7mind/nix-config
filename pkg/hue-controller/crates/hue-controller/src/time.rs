//! Clock abstraction. Lets the controller take its current time-of-day
//! and monotonic timestamps from a trait, so unit tests can drive a fake
//! clock instead of relying on `std::time::Instant::now()` and the system
//! timezone.
//!
//! Two pieces of "now" the controller needs:
//!
//!   1. A monotonic [`Instant`] for the cycle window comparison
//!      (`now - last_press_at < cycle_pause`).
//!   2. The current local hour (0..=23) for slot dispatch (day vs night
//!      cycle order).
//!
//! Both flow through this trait so a test can advance time in millisecond
//! increments and shift the local hour with a single line.

use std::time::{Duration, Instant};

use chrono::Timelike;
use chrono_tz::Tz;

/// Source of "now" for the controller. The runtime uses [`SystemClock`];
/// tests use [`FakeClock`].
pub trait Clock: std::fmt::Debug + Send + Sync {
    /// Monotonic timestamp suitable for elapsed-time comparisons. The
    /// runtime uses `Instant::now()`; the fake clock uses an internal
    /// counter.
    fn now(&self) -> Instant;

    /// Local hour (0..=23) used for time-of-day slot dispatch. Returned
    /// as a `u8` because that's the type the slot ranges use.
    fn local_hour(&self) -> u8;

    /// Local minute (0..=59) used for scheduled action triggers.
    fn local_minute(&self) -> u8;
}

/// Production clock. Time-of-day comes from a configured IANA timezone so
/// raspi5m always agrees with itself even after DST transitions.
#[derive(Debug)]
pub struct SystemClock {
    timezone: Tz,
}

impl SystemClock {
    pub fn new(timezone: Tz) -> Self {
        Self { timezone }
    }
}

impl Clock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }

    fn local_hour(&self) -> u8 {
        let now = chrono::Utc::now().with_timezone(&self.timezone);
        now.hour() as u8
    }

    fn local_minute(&self) -> u8 {
        let now = chrono::Utc::now().with_timezone(&self.timezone);
        now.minute() as u8
    }
}

/// Test clock. The current `Instant` and local hour are both stored
/// behind interior mutability so tests can advance them without taking a
/// `&mut` reference (the controller holds the clock as `&dyn Clock`).
#[derive(Debug)]
pub struct FakeClock {
    inner: std::sync::Mutex<FakeClockInner>,
}

#[derive(Debug)]
struct FakeClockInner {
    now: Instant,
    hour: u8,
    minute: u8,
}

impl FakeClock {
    /// Construct a fake clock with the given starting hour. The internal
    /// `Instant` is whatever the OS hands us at construction time, which
    /// is fine because every test only ever observes *deltas*.
    pub fn new(hour: u8) -> Self {
        Self {
            inner: std::sync::Mutex::new(FakeClockInner {
                now: Instant::now(),
                hour,
                minute: 0,
            }),
        }
    }

    /// Advance the monotonic clock by `d`. Subsequent `now()` calls
    /// return the advanced value.
    pub fn advance(&self, d: Duration) {
        let mut inner = self.inner.lock().expect("FakeClock mutex poisoned");
        inner.now += d;
    }

    /// Set the local hour. Useful for testing slot transitions without
    /// having to also advance the monotonic clock by 24 hours.
    pub fn set_hour(&self, hour: u8) {
        let mut inner = self.inner.lock().expect("FakeClock mutex poisoned");
        inner.hour = hour;
    }

    /// Set the local minute.
    pub fn set_minute(&self, minute: u8) {
        let mut inner = self.inner.lock().expect("FakeClock mutex poisoned");
        inner.minute = minute;
    }
}

impl Clock for FakeClock {
    fn now(&self) -> Instant {
        self.inner.lock().expect("FakeClock mutex poisoned").now
    }

    fn local_hour(&self) -> u8 {
        self.inner.lock().expect("FakeClock mutex poisoned").hour
    }

    fn local_minute(&self) -> u8 {
        self.inner.lock().expect("FakeClock mutex poisoned").minute
    }
}

#[cfg(test)]
mod tests {
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
}
