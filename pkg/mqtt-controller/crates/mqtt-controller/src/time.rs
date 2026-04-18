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

use chrono::{Datelike, NaiveDate, Offset, Timelike};
use chrono_tz::Tz;

use crate::config::heating::Weekday;

/// Date information for sunrise/sunset computation.
#[derive(Debug, Clone, Copy)]
pub struct DateInfo {
    pub date: NaiveDate,
    pub utc_offset_hours: f64,
}

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

    /// Local weekday. Used by the heating subsystem for temperature
    /// schedule evaluation.
    fn local_weekday(&self) -> Weekday;

    /// Wall-clock milliseconds since the Unix epoch. Used for wire
    /// protocol timestamps (snapshot and decision-log entries).
    fn epoch_millis(&self) -> u64;

    /// Local date and UTC offset. Used for sunrise/sunset calculations.
    fn local_date_info(&self) -> DateInfo;
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

    fn local_weekday(&self) -> Weekday {
        let now = chrono::Utc::now().with_timezone(&self.timezone);
        match now.weekday() {
            chrono::Weekday::Mon => Weekday::Monday,
            chrono::Weekday::Tue => Weekday::Tuesday,
            chrono::Weekday::Wed => Weekday::Wednesday,
            chrono::Weekday::Thu => Weekday::Thursday,
            chrono::Weekday::Fri => Weekday::Friday,
            chrono::Weekday::Sat => Weekday::Saturday,
            chrono::Weekday::Sun => Weekday::Sunday,
        }
    }

    fn epoch_millis(&self) -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }

    fn local_date_info(&self) -> DateInfo {
        let now = chrono::Utc::now().with_timezone(&self.timezone);
        let utc_time = chrono::Utc::now();
        let local_time = utc_time.with_timezone(&self.timezone);
        let offset_secs = local_time.offset().fix().local_minus_utc();
        DateInfo {
            date: now.date_naive(),
            utc_offset_hours: offset_secs as f64 / 3600.0,
        }
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
    weekday: Weekday,
    epoch_millis: u64,
    date_info: DateInfo,
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
                weekday: Weekday::Monday,
                epoch_millis: 1_700_000_000_000,
                date_info: DateInfo {
                    date: NaiveDate::from_ymd_opt(2026, 4, 11).unwrap(),
                    utc_offset_hours: 1.0,
                },
            }),
        }
    }

    /// Advance the monotonic clock and epoch time by `d`. Subsequent
    /// `now()` and `epoch_millis()` calls return the advanced values.
    pub fn advance(&self, d: Duration) {
        let mut inner = self.inner.lock().expect("FakeClock mutex poisoned");
        inner.now += d;
        inner.epoch_millis += d.as_millis() as u64;
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

    /// Set the local weekday.
    pub fn set_weekday(&self, weekday: Weekday) {
        let mut inner = self.inner.lock().expect("FakeClock mutex poisoned");
        inner.weekday = weekday;
    }

    /// Set the local date info for sun calculations.
    pub fn set_date_info(&self, date_info: DateInfo) {
        let mut inner = self.inner.lock().expect("FakeClock mutex poisoned");
        inner.date_info = date_info;
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

    fn local_weekday(&self) -> Weekday {
        self.inner.lock().expect("FakeClock mutex poisoned").weekday
    }

    fn epoch_millis(&self) -> u64 {
        self.inner.lock().expect("FakeClock mutex poisoned").epoch_millis
    }

    fn local_date_info(&self) -> DateInfo {
        self.inner.lock().expect("FakeClock mutex poisoned").date_info
    }
}

#[cfg(test)]
#[path = "time_tests.rs"]
mod tests;
