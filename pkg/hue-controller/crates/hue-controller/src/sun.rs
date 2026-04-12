//! Sunrise/sunset computation for sun-relative schedule expressions.
//!
//! Thin wrapper around the [`sunrise`] crate.

use chrono::{NaiveDate, Timelike};
use serde::{Deserialize, Serialize};
use sunrise::{Coordinates, SolarDay, SolarEvent};

/// Geographic coordinates for sun position calculations.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Location {
    pub latitude: f64,
    pub longitude: f64,
}

/// Precomputed sunrise/sunset for a single calendar day, as
/// minutes-since-midnight in local time.
#[derive(Debug, Clone, Copy)]
pub struct SunTimes {
    pub sunrise_minute_of_day: u16,
    pub sunset_minute_of_day: u16,
}

/// Compute sunrise and sunset for the given date and location.
///
/// `utc_offset_hours` is the local timezone's offset from UTC (e.g. +1.0
/// for CET, +2.0 for CEST). Times are returned as minutes since local
/// midnight.
pub fn compute_sun_times(
    location: &Location,
    date: NaiveDate,
    utc_offset_hours: f64,
) -> SunTimes {
    let coords = Coordinates::new(location.latitude, location.longitude)
        .expect("invalid coordinates");
    let day = SolarDay::new(coords, date);

    let to_local_minutes = |event: SolarEvent| -> u16 {
        // event_time returns NaiveDateTime in UTC.
        let utc = day.event_time(event).expect("sun event has no solution (polar region?)");
        let total_utc_min = utc.time().hour() as f64 * 60.0 + utc.time().minute() as f64;
        let local_min = total_utc_min + utc_offset_hours * 60.0;
        local_min.round().rem_euclid(1440.0) as u16
    };

    SunTimes {
        sunrise_minute_of_day: to_local_minutes(SolarEvent::Sunrise),
        sunset_minute_of_day: to_local_minutes(SolarEvent::Sunset),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dublin_spring_equinox_reasonable() {
        let loc = Location { latitude: 53.35, longitude: -6.26 };
        let date = NaiveDate::from_ymd_opt(2026, 3, 20).unwrap();
        let sun = compute_sun_times(&loc, date, 0.0); // GMT (no DST)
        // Sunrise ~06:20, sunset ~18:30 around spring equinox in Dublin.
        assert!(sun.sunrise_minute_of_day > 350 && sun.sunrise_minute_of_day < 420,
            "sunrise {} not in expected range", sun.sunrise_minute_of_day);
        assert!(sun.sunset_minute_of_day > 1080 && sun.sunset_minute_of_day < 1140,
            "sunset {} not in expected range", sun.sunset_minute_of_day);
    }

    #[test]
    fn utc_offset_shifts_times() {
        let loc = Location { latitude: 53.35, longitude: -6.26 };
        let date = NaiveDate::from_ymd_opt(2026, 6, 21).unwrap();
        let gmt = compute_sun_times(&loc, date, 0.0);
        let ist = compute_sun_times(&loc, date, 1.0); // IST = GMT+1
        assert_eq!(ist.sunrise_minute_of_day, gmt.sunrise_minute_of_day + 60);
    }
}
