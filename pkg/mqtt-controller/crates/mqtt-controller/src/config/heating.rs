//! Heating zone configuration: temperature schedules, TRV-to-zone
//! assignments, pressure groups, heat pump short-cycling protection,
//! and open window detection parameters.
//!
//! The heating subsystem is optional — hosts that don't have TRVs or
//! wall thermostats simply omit the `heating` key from the JSON config.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use thiserror::Error;

// ---- Weekday ---------------------------------------------------------------

/// Day of the week. Serializes as lowercase string for JSON readability.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Weekday {
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,
    Sunday,
}

impl Weekday {
    pub const ALL: [Weekday; 7] = [
        Weekday::Monday,
        Weekday::Tuesday,
        Weekday::Wednesday,
        Weekday::Thursday,
        Weekday::Friday,
        Weekday::Saturday,
        Weekday::Sunday,
    ];
}

impl std::fmt::Display for Weekday {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            Self::Monday => "monday",
            Self::Tuesday => "tuesday",
            Self::Wednesday => "wednesday",
            Self::Thursday => "thursday",
            Self::Friday => "friday",
            Self::Saturday => "saturday",
            Self::Sunday => "sunday",
        };
        f.write_str(s)
    }
}

// ---- Time range ------------------------------------------------------------

/// A time range within a single day with an associated target temperature.
/// `end` is exclusive. No midnight crossing: start must be strictly before
/// end within the same day (00:00 to 24:00).
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct DayTimeRange {
    pub start_hour: u8,
    pub start_minute: u8,
    /// Exclusive end hour. 24 means midnight (end of day).
    pub end_hour: u8,
    /// Exclusive end minute. Must be 0 when end_hour is 24.
    pub end_minute: u8,
    /// Target temperature in °C. Must be in 5.0..=30.0 (BTH-RA range).
    pub temperature: f64,
}

impl DayTimeRange {
    /// Start time as total minutes from midnight.
    fn start_minutes(&self) -> u32 {
        self.start_hour as u32 * 60 + self.start_minute as u32
    }

    /// End time as total minutes from midnight (exclusive).
    fn end_minutes(&self) -> u32 {
        self.end_hour as u32 * 60 + self.end_minute as u32
    }

    /// True if the given hour:minute falls within this range (inclusive
    /// start, exclusive end).
    pub fn contains(&self, hour: u8, minute: u8) -> bool {
        let t = hour as u32 * 60 + minute as u32;
        t >= self.start_minutes() && t < self.end_minutes()
    }
}

// ---- Temperature schedule --------------------------------------------------

/// A named temperature schedule covering a full week. Each weekday has
/// a list of non-overlapping time ranges that together cover [00:00, 24:00).
///
/// NOTE: no `deny_unknown_fields` here because `#[serde(flatten)]` on the
/// `days` map is incompatible with it (same issue as `DeviceCatalogEntry`,
/// see `catalog.rs`). Our validation logic checks all 7 weekdays are
/// present, so malformed schedules are still caught at startup.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TemperatureSchedule {
    /// Day → ordered list of time ranges. All 7 weekdays must be present.
    #[serde(flatten)]
    pub days: BTreeMap<Weekday, Vec<DayTimeRange>>,
}

/// A TRV within a heating zone.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ZoneTrv {
    /// TRV device friendly_name. Must reference a `trv` kind in the catalog.
    pub device: String,
    /// Name of the temperature schedule to use. Must reference a key in
    /// `HeatingConfig::schedules`.
    pub schedule: String,
}

/// One heating zone. Each zone has exactly one relay (a wall thermostat
/// acting as a relay for a floor heating circuit) and one or more TRVs.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HeatingZone {
    /// Unique zone name. Used as the key in runtime state maps.
    pub name: String,
    /// Wall thermostat device friendly_name acting as relay for this zone.
    /// Must reference a `wall-thermostat` kind in the catalog.
    pub relay: String,
    /// TRVs in this zone. At least one required.
    pub trvs: Vec<ZoneTrv>,
}

/// A pressure group. All TRVs in a group must be from the same zone.
/// When any TRV in the group has its valve open, all others are forced
/// open to maintain safe pressure distribution.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PressureGroup {
    /// Unique group name. Used for logging.
    pub name: String,
    /// TRV device friendly_names. Must be ≥ 2 (a single-TRV group is
    /// meaningless) and all from the same zone.
    pub trvs: Vec<String>,
}

/// Heat pump short-cycling protection. Since all wall thermostats control
/// the same heat pump, protection is global: min_pause is enforced from
/// the moment the LAST relay turns off until any relay may turn on;
/// min_cycle is enforced from the moment the FIRST relay turns on until
/// the last relay may turn off.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HeatPumpProtection {
    /// Minimum time (seconds) the pump must run once started (i.e. at
    /// least one relay must stay on for this long).
    pub min_cycle_seconds: u64,
    /// Minimum pause (seconds) after the pump stops (all relays off)
    /// before any relay may turn on again.
    pub min_pause_seconds: u64,
}

/// Open window protection. Per-TRV: if temperature doesn't rise within
/// `detection_minutes` after the zone relay turns on, the TRV is inhibited
/// (setpoint lowered to minimum, excluded from demand evaluation) for
/// `inhibit_minutes`.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct OpenWindowProtection {
    /// Minutes after relay turns on to check for temperature rise.
    pub detection_minutes: u32,
    /// Minutes to inhibit a TRV after open window is detected.
    pub inhibit_minutes: u32,
}

/// Top-level heating configuration. Optional in the controller config —
/// hosts without heating devices omit this entirely.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HeatingConfig {
    pub zones: Vec<HeatingZone>,
    pub schedules: BTreeMap<String, TemperatureSchedule>,
    #[serde(default)]
    pub pressure_groups: Vec<PressureGroup>,
    pub heat_pump: HeatPumpProtection,
    pub open_window: OpenWindowProtection,
}

// ---- Validation ------------------------------------------------------------

#[derive(Debug, Error, PartialEq)]
pub enum HeatingConfigError {
    #[error("schedule {schedule:?}: missing weekday {day}")]
    MissingWeekday { schedule: String, day: Weekday },

    #[error(
        "schedule {schedule:?}, {day}: range {idx} has start_hour {hour} out of range (0..=23)"
    )]
    StartHourOutOfRange {
        schedule: String,
        day: Weekday,
        idx: usize,
        hour: u8,
    },

    #[error(
        "schedule {schedule:?}, {day}: range {idx} has end_hour {hour} out of range (0..=24)"
    )]
    EndHourOutOfRange {
        schedule: String,
        day: Weekday,
        idx: usize,
        hour: u8,
    },

    #[error("schedule {schedule:?}, {day}: range {idx} has minute {minute} out of range (0..=59)")]
    MinuteOutOfRange {
        schedule: String,
        day: Weekday,
        idx: usize,
        minute: u8,
    },

    #[error(
        "schedule {schedule:?}, {day}: range {idx} has end_minute {minute} != 0 when end_hour is 24"
    )]
    EndMinuteWith24 {
        schedule: String,
        day: Weekday,
        idx: usize,
        minute: u8,
    },

    #[error(
        "schedule {schedule:?}, {day}: range {idx} crosses midnight \
         (start {start_h}:{start_m:02} >= end {end_h}:{end_m:02})"
    )]
    MidnightCrossing {
        schedule: String,
        day: Weekday,
        idx: usize,
        start_h: u8,
        start_m: u8,
        end_h: u8,
        end_m: u8,
    },

    #[error(
        "schedule {schedule:?}, {day}: temperature {temp} out of range 5.0..=30.0 in range {idx}"
    )]
    TemperatureOutOfRange {
        schedule: String,
        day: Weekday,
        idx: usize,
        temp: f64,
    },

    #[error(
        "schedule {schedule:?}, {day}: ranges {idx_a} and {idx_b} overlap \
         at minute {minute}"
    )]
    OverlappingRanges {
        schedule: String,
        day: Weekday,
        idx_a: usize,
        idx_b: usize,
        minute: u32,
    },

    #[error(
        "schedule {schedule:?}, {day}: minute {minute} is not covered by any range"
    )]
    GapInCoverage {
        schedule: String,
        day: Weekday,
        minute: u32,
    },

    #[error("zone {zone:?}: duplicate zone name")]
    DuplicateZoneName { zone: String },

    #[error("zone {zone:?}: relay {relay:?} is not a wall-thermostat in the device catalog")]
    RelayNotWallThermostat { zone: String, relay: String },

    #[error("zone {zone:?}: TRV {trv:?} is not a trv in the device catalog")]
    TrvNotInCatalog { zone: String, trv: String },

    #[error("zone {zone:?}: TRV {trv:?} references unknown schedule {schedule:?}")]
    UnknownSchedule {
        zone: String,
        trv: String,
        schedule: String,
    },

    #[error("TRV {trv:?} appears in multiple zones: {zone_a:?} and {zone_b:?}")]
    TrvInMultipleZones {
        trv: String,
        zone_a: String,
        zone_b: String,
    },

    #[error("pressure group {group:?}: must have at least 2 TRVs")]
    PressureGroupTooSmall { group: String },

    #[error(
        "pressure group {group:?}: TRV {trv:?} is not in any heating zone"
    )]
    PressureGroupTrvNotInZone { group: String, trv: String },

    #[error(
        "pressure group {group:?}: TRVs span multiple zones \
         ({zone_a:?} and {zone_b:?})"
    )]
    PressureGroupMultipleZones {
        group: String,
        zone_a: String,
        zone_b: String,
    },

    #[error(
        "TRV {trv:?} appears in multiple pressure groups: {group_a:?} and {group_b:?}"
    )]
    TrvInMultiplePressureGroups {
        trv: String,
        group_a: String,
        group_b: String,
    },

    #[error("zone {zone:?}: has no TRVs")]
    ZoneEmpty { zone: String },

    #[error("zone {zone:?}: relay {relay:?} is used by another zone {other_zone:?}")]
    DuplicateRelay {
        zone: String,
        relay: String,
        other_zone: String,
    },

    #[error(
        "zone {zone:?}: relay {relay:?} is missing options.heater_type = \"manual_control\" — \
         without this the wall thermostat's internal algorithm ignores relay commands"
    )]
    RelayMissingManualControl { zone: String, relay: String },
}

impl TemperatureSchedule {
    /// Validate that this schedule covers every minute of every weekday
    /// with no gaps, overlaps, or midnight-crossing ranges.
    pub fn validate(&self, name: &str) -> Result<(), HeatingConfigError> {
        for &day in &Weekday::ALL {
            let ranges = self.days.get(&day).ok_or_else(|| {
                HeatingConfigError::MissingWeekday {
                    schedule: name.into(),
                    day,
                }
            })?;

            // Validate individual ranges.
            for (idx, r) in ranges.iter().enumerate() {
                if r.start_hour > 23 {
                    return Err(HeatingConfigError::StartHourOutOfRange {
                        schedule: name.into(),
                        day,
                        idx,
                        hour: r.start_hour,
                    });
                }
                if r.end_hour > 24 {
                    return Err(HeatingConfigError::EndHourOutOfRange {
                        schedule: name.into(),
                        day,
                        idx,
                        hour: r.end_hour,
                    });
                }
                if r.start_minute > 59 {
                    return Err(HeatingConfigError::MinuteOutOfRange {
                        schedule: name.into(),
                        day,
                        idx,
                        minute: r.start_minute,
                    });
                }
                if r.end_hour < 24 && r.end_minute > 59 {
                    return Err(HeatingConfigError::MinuteOutOfRange {
                        schedule: name.into(),
                        day,
                        idx,
                        minute: r.end_minute,
                    });
                }
                if r.end_hour == 24 && r.end_minute != 0 {
                    return Err(HeatingConfigError::EndMinuteWith24 {
                        schedule: name.into(),
                        day,
                        idx,
                        minute: r.end_minute,
                    });
                }
                // No midnight crossing: start < end.
                if r.start_minutes() >= r.end_minutes() {
                    return Err(HeatingConfigError::MidnightCrossing {
                        schedule: name.into(),
                        day,
                        idx,
                        start_h: r.start_hour,
                        start_m: r.start_minute,
                        end_h: r.end_hour,
                        end_m: r.end_minute,
                    });
                }
                if !(5.0..=30.0).contains(&r.temperature) {
                    return Err(HeatingConfigError::TemperatureOutOfRange {
                        schedule: name.into(),
                        day,
                        idx,
                        temp: r.temperature,
                    });
                }
            }

            // Check coverage: every minute 0..1440 must be covered by
            // exactly one range.
            validate_day_coverage(name, day, ranges)?;
        }
        Ok(())
    }

    /// Look up the target temperature for a given weekday, hour, and minute.
    /// Returns `None` only if the schedule is invalid (gap in coverage).
    pub fn target_temperature(&self, day: Weekday, hour: u8, minute: u8) -> Option<f64> {
        let ranges = self.days.get(&day)?;
        ranges
            .iter()
            .find(|r| r.contains(hour, minute))
            .map(|r| r.temperature)
    }
}

/// Validate that the ranges for one weekday cover [0, 1440) with no gaps
/// or overlaps. Uses a sweep-line approach: sort by start, check adjacency.
fn validate_day_coverage(
    schedule_name: &str,
    day: Weekday,
    ranges: &[DayTimeRange],
) -> Result<(), HeatingConfigError> {
    if ranges.is_empty() {
        return Err(HeatingConfigError::GapInCoverage {
            schedule: schedule_name.into(),
            day,
            minute: 0,
        });
    }

    // Build (start_min, end_min, original_index) and sort by start.
    let mut intervals: Vec<(u32, u32, usize)> = ranges
        .iter()
        .enumerate()
        .map(|(i, r)| (r.start_minutes(), r.end_minutes(), i))
        .collect();
    intervals.sort_by_key(|&(s, _, _)| s);

    // Check that intervals tile [0, 1440) exactly.
    // First interval must start at 0.
    if intervals[0].0 != 0 {
        return Err(HeatingConfigError::GapInCoverage {
            schedule: schedule_name.into(),
            day,
            minute: 0,
        });
    }

    let mut covered_until: u32 = 0;
    for &(start, end, idx) in &intervals {
        if start < covered_until {
            // Find which previous interval overlaps.
            let prev_idx = intervals
                .iter()
                .find(|&&(s, e, i)| i != idx && s < end && e > start)
                .map(|&(_, _, i)| i)
                .unwrap_or(0);
            return Err(HeatingConfigError::OverlappingRanges {
                schedule: schedule_name.into(),
                day,
                idx_a: prev_idx,
                idx_b: idx,
                minute: start,
            });
        }
        if start > covered_until {
            return Err(HeatingConfigError::GapInCoverage {
                schedule: schedule_name.into(),
                day,
                minute: covered_until,
            });
        }
        covered_until = end;
    }

    // Must reach 1440 (24:00).
    if covered_until != 1440 {
        return Err(HeatingConfigError::GapInCoverage {
            schedule: schedule_name.into(),
            day,
            minute: covered_until,
        });
    }

    Ok(())
}

impl HeatingConfig {
    /// Validate all schedules. Zone/device cross-references are validated
    /// by the topology builder which has access to the device catalog.
    pub fn validate_schedules(&self) -> Result<(), HeatingConfigError> {
        for (name, schedule) in &self.schedules {
            schedule.validate(name)?;
        }
        Ok(())
    }
}

// ---- Tests -----------------------------------------------------------------

#[cfg(test)]
mod tests {
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
                    "monday": [{"start_hour": 0, "start_minute": 0, "end_hour": 24, "end_minute": 0, "temperature": 20.0}],
                    "tuesday": [{"start_hour": 0, "start_minute": 0, "end_hour": 24, "end_minute": 0, "temperature": 20.0}],
                    "wednesday": [{"start_hour": 0, "start_minute": 0, "end_hour": 24, "end_minute": 0, "temperature": 20.0}],
                    "thursday": [{"start_hour": 0, "start_minute": 0, "end_hour": 24, "end_minute": 0, "temperature": 20.0}],
                    "friday": [{"start_hour": 0, "start_minute": 0, "end_hour": 24, "end_minute": 0, "temperature": 20.0}],
                    "saturday": [{"start_hour": 0, "start_minute": 0, "end_hour": 24, "end_minute": 0, "temperature": 20.0}],
                    "sunday": [{"start_hour": 0, "start_minute": 0, "end_hour": 24, "end_minute": 0, "temperature": 20.0}]
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
}
