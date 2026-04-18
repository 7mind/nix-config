//! Tests for `sun`. Split out so `sun.rs` stays focused on
//! production code. See `sun.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

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
