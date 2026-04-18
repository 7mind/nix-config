//! Tests for `heating`. Split out so `heating.rs` stays focused on
//! production code. See `heating.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;

fn full_day(temp: f64) -> Vec<DayTimeRange> {
    vec![DayTimeRange {
        start_hour: 0,
        start_minute: 0,
        end_hour: 24,
        end_minute: 0,
        temperature: temp,
    }]
}

fn full_week(temp: f64) -> BTreeMap<Weekday, Vec<DayTimeRange>> {
    Weekday::ALL
        .iter()
        .map(|&d| (d, full_day(temp)))
        .collect()
}

fn typical_day() -> Vec<DayTimeRange> {
    vec![
        DayTimeRange {
            start_hour: 0,
            start_minute: 0,
            end_hour: 6,
            end_minute: 0,
            temperature: 18.0,
        },
        DayTimeRange {
            start_hour: 6,
            start_minute: 0,
            end_hour: 8,
            end_minute: 30,
            temperature: 22.0,
        },
        DayTimeRange {
            start_hour: 8,
            start_minute: 30,
            end_hour: 17,
            end_minute: 0,
            temperature: 18.0,
        },
        DayTimeRange {
            start_hour: 17,
            start_minute: 0,
            end_hour: 22,
            end_minute: 0,
            temperature: 22.0,
        },
        DayTimeRange {
            start_hour: 22,
            start_minute: 0,
            end_hour: 24,
            end_minute: 0,
            temperature: 18.0,
        },
    ]
}

#[test]
fn valid_full_week_constant_temp() {
    let schedule = TemperatureSchedule {
        days: full_week(20.0),
    };
    schedule.validate("test").unwrap();
}

#[test]
fn valid_typical_schedule() {
    let mut days = BTreeMap::new();
    for &d in &Weekday::ALL {
        days.insert(d, typical_day());
    }
    let schedule = TemperatureSchedule { days };
    schedule.validate("typical").unwrap();
}

#[test]
fn target_temperature_lookup() {
    let schedule = TemperatureSchedule {
        days: {
            let mut d = full_week(18.0);
            d.insert(Weekday::Monday, typical_day());
            d
        },
    };
    schedule.validate("test").unwrap();
    // 07:00 Monday → 22.0 (morning heating)
    assert_eq!(
        schedule.target_temperature(Weekday::Monday, 7, 0),
        Some(22.0)
    );
    // 12:00 Monday → 18.0 (midday setback)
    assert_eq!(
        schedule.target_temperature(Weekday::Monday, 12, 0),
        Some(18.0)
    );
    // 03:00 Tuesday → 18.0 (constant for other days)
    assert_eq!(
        schedule.target_temperature(Weekday::Tuesday, 3, 0),
        Some(18.0)
    );
}

#[test]
fn missing_weekday_rejected() {
    let mut days = full_week(20.0);
    days.remove(&Weekday::Wednesday);
    let schedule = TemperatureSchedule { days };
    let err = schedule.validate("test").unwrap_err();
    assert!(matches!(
        err,
        HeatingConfigError::MissingWeekday {
            day: Weekday::Wednesday,
            ..
        }
    ));
}

#[test]
fn midnight_crossing_rejected() {
    let mut days = full_week(20.0);
    days.insert(
        Weekday::Monday,
        vec![DayTimeRange {
            start_hour: 22,
            start_minute: 0,
            end_hour: 6,
            end_minute: 0,
            temperature: 18.0,
        }],
    );
    let schedule = TemperatureSchedule { days };
    let err = schedule.validate("test").unwrap_err();
    assert!(matches!(err, HeatingConfigError::MidnightCrossing { .. }));
}

#[test]
fn zero_length_range_rejected() {
    let mut days = full_week(20.0);
    days.insert(
        Weekday::Monday,
        vec![
            DayTimeRange {
                start_hour: 0,
                start_minute: 0,
                end_hour: 0,
                end_minute: 0,
                temperature: 20.0,
            },
            DayTimeRange {
                start_hour: 0,
                start_minute: 0,
                end_hour: 24,
                end_minute: 0,
                temperature: 20.0,
            },
        ],
    );
    let schedule = TemperatureSchedule { days };
    let err = schedule.validate("test").unwrap_err();
    assert!(matches!(err, HeatingConfigError::MidnightCrossing { .. }));
}

#[test]
fn gap_in_coverage_rejected() {
    let mut days = full_week(20.0);
    // Cover 0:00-12:00 and 13:00-24:00 — gap at 12:00-13:00.
    days.insert(
        Weekday::Monday,
        vec![
            DayTimeRange {
                start_hour: 0,
                start_minute: 0,
                end_hour: 12,
                end_minute: 0,
                temperature: 20.0,
            },
            DayTimeRange {
                start_hour: 13,
                start_minute: 0,
                end_hour: 24,
                end_minute: 0,
                temperature: 20.0,
            },
        ],
    );
    let schedule = TemperatureSchedule { days };
    let err = schedule.validate("test").unwrap_err();
    assert!(matches!(
        err,
        HeatingConfigError::GapInCoverage { minute: 720, .. }
    ));
}

#[test]
fn overlap_rejected() {
    let mut days = full_week(20.0);
    days.insert(
        Weekday::Monday,
        vec![
            DayTimeRange {
                start_hour: 0,
                start_minute: 0,
                end_hour: 13,
                end_minute: 0,
                temperature: 20.0,
            },
            DayTimeRange {
                start_hour: 12,
                start_minute: 0,
                end_hour: 24,
                end_minute: 0,
                temperature: 20.0,
            },
        ],
    );
    let schedule = TemperatureSchedule { days };
    let err = schedule.validate("test").unwrap_err();
    assert!(matches!(
        err,
        HeatingConfigError::OverlappingRanges { .. }
    ));
}

#[test]
fn temperature_out_of_range_rejected() {
    let mut days = full_week(20.0);
    days.insert(
        Weekday::Monday,
        vec![DayTimeRange {
            start_hour: 0,
            start_minute: 0,
            end_hour: 24,
            end_minute: 0,
            temperature: 35.0,
        }],
    );
    let schedule = TemperatureSchedule { days };
    let err = schedule.validate("test").unwrap_err();
    assert!(matches!(
        err,
        HeatingConfigError::TemperatureOutOfRange { .. }
    ));
}

#[test]
fn temperature_below_min_rejected() {
    let mut days = full_week(20.0);
    days.insert(
        Weekday::Monday,
        vec![DayTimeRange {
            start_hour: 0,
            start_minute: 0,
            end_hour: 24,
            end_minute: 0,
            temperature: 4.0,
        }],
    );
    let schedule = TemperatureSchedule { days };
    let err = schedule.validate("test").unwrap_err();
    assert!(matches!(
        err,
        HeatingConfigError::TemperatureOutOfRange { .. }
    ));
}

#[test]
fn end_hour_24_with_nonzero_minute_rejected() {
    let mut days = full_week(20.0);
    days.insert(
        Weekday::Monday,
        vec![DayTimeRange {
            start_hour: 0,
            start_minute: 0,
            end_hour: 24,
            end_minute: 30,
            temperature: 20.0,
        }],
    );
    let schedule = TemperatureSchedule { days };
    let err = schedule.validate("test").unwrap_err();
    assert!(matches!(
        err,
        HeatingConfigError::EndMinuteWith24 { .. }
    ));
}

#[test]
fn minute_boundaries_work() {
    let mut days = full_week(20.0);
    days.insert(
        Weekday::Monday,
        vec![
            DayTimeRange {
                start_hour: 0,
                start_minute: 0,
                end_hour: 6,
                end_minute: 30,
                temperature: 18.0,
            },
            DayTimeRange {
                start_hour: 6,
                start_minute: 30,
                end_hour: 24,
                end_minute: 0,
                temperature: 22.0,
            },
        ],
    );
    let schedule = TemperatureSchedule { days };
    schedule.validate("boundary").unwrap();
    // 06:29 → 18.0, 06:30 → 22.0
    assert_eq!(
        schedule.target_temperature(Weekday::Monday, 6, 29),
        Some(18.0)
    );
    assert_eq!(
        schedule.target_temperature(Weekday::Monday, 6, 30),
        Some(22.0)
    );
}

#[test]
fn day_time_range_contains_boundary() {
    let r = DayTimeRange {
        start_hour: 8,
        start_minute: 30,
        end_hour: 17,
        end_minute: 0,
        temperature: 22.0,
    };
    assert!(!r.contains(8, 29));
    assert!(r.contains(8, 30));
    assert!(r.contains(16, 59));
    assert!(!r.contains(17, 0));
}

#[test]
fn deserialize_heating_config() {
    let json = r#"{
        "zones": [{
            "name": "bathroom",
            "relay": "bosch-wt-bath",
            "trvs": [{"device": "bosch-trv-bath-1", "schedule": "bath-sched"}]
        }],
        "schedules": {
            "bath-sched": {
                "monday": [{"start": "00:00", "end": "24:00", "temperature": 20.0}],
                "tuesday": [{"start": "00:00", "end": "24:00", "temperature": 20.0}],
                "wednesday": [{"start": "00:00", "end": "24:00", "temperature": 20.0}],
                "thursday": [{"start": "00:00", "end": "24:00", "temperature": 20.0}],
                "friday": [{"start": "00:00", "end": "24:00", "temperature": 20.0}],
                "saturday": [{"start": "00:00", "end": "24:00", "temperature": 20.0}],
                "sunday": [{"start": "00:00", "end": "24:00", "temperature": 20.0}]
            }
        },
        "pressure_groups": [],
        "heat_pump": {"min_cycle_seconds": 300, "min_pause_seconds": 180},
        "open_window": {"detection_minutes": 20, "inhibit_minutes": 80}
    }"#;
    let config: HeatingConfig = serde_json::from_str(json).unwrap();
    assert_eq!(config.zones.len(), 1);
    assert_eq!(config.zones[0].name, "bathroom");
    config.validate_schedules().unwrap();
}

#[test]
fn unknown_field_in_heating_config_rejected() {
    let json = r#"{
        "zones": [],
        "schedules": {},
        "pressure_groups": [],
        "heat_pump": {"min_cycle_seconds": 300, "min_pause_seconds": 180},
        "open_window": {"detection_minutes": 20, "inhibit_minutes": 80},
        "ghost": true
    }"#;
    let result: Result<HeatingConfig, _> = serde_json::from_str(json);
    assert!(result.is_err());
}
