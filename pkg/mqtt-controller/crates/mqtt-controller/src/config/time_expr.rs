//! Time expression: either a fixed `HH:MM` or a sun-relative
//! `sunrise/sunset ± HH:MM`.
//!
//! Parsed from a string in the JSON config. Examples:
//!   - `"06:00"`          → Fixed 06:00
//!   - `"23:00"`          → Fixed 23:00
//!   - `"24:00"`          → Fixed 24:00 (exclusive end-of-day sentinel)
//!   - `"sunset"`         → Sun-relative, sunset + 0
//!   - `"sunset-01:00"`   → Sun-relative, sunset − 60 min
//!   - `"sunrise+01:30"`  → Sun-relative, sunrise + 90 min

use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize, de, ser};

use crate::sun::SunTimes;

/// A time-of-day expression used as a slot boundary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TimeExpr {
    /// A fixed clock time. `minute_of_day` is 0..=1440 (1440 = 24:00,
    /// the exclusive end-of-day sentinel).
    Fixed { minute_of_day: u16 },
    /// A time relative to a solar event.
    SunRelative { event: SunEvent, offset_minutes: i16 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SunEvent {
    Sunrise,
    Sunset,
}

impl TimeExpr {
    /// Resolve to minutes-since-midnight (0..=1440). For `Fixed`, returns
    /// the stored value directly. For `SunRelative`, computes base + offset
    /// using the provided sun times.
    pub fn resolve(&self, sun: Option<&SunTimes>) -> u16 {
        match self {
            TimeExpr::Fixed { minute_of_day } => *minute_of_day,
            TimeExpr::SunRelative { event, offset_minutes } => {
                let sun = sun.expect("sun times required for sun-relative expression");
                let base = match event {
                    SunEvent::Sunrise => sun.sunrise_minute_of_day,
                    SunEvent::Sunset => sun.sunset_minute_of_day,
                };
                let raw = base as i32 + *offset_minutes as i32;
                raw.clamp(0, 1440) as u16
            }
        }
    }

    /// True if this expression depends on solar position.
    pub fn uses_sun(&self) -> bool {
        matches!(self, TimeExpr::SunRelative { .. })
    }
}

// ---- Parsing ---------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseTimeExprError(pub String);

impl fmt::Display for ParseTimeExprError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "invalid time expression: {}", self.0)
    }
}

impl std::error::Error for ParseTimeExprError {}

/// Parse `HH:MM` into (hour, minute). Accepts 00:00 through 24:00.
pub(crate) fn parse_hhmm(s: &str) -> Result<(u8, u8), ParseTimeExprError> {
    let (hh, mm) = s.split_once(':').ok_or_else(|| {
        ParseTimeExprError(format!("{s:?}: expected HH:MM"))
    })?;
    let h: u8 = hh.parse().map_err(|_| {
        ParseTimeExprError(format!("{s:?}: invalid hour"))
    })?;
    let m: u8 = mm.parse().map_err(|_| {
        ParseTimeExprError(format!("{s:?}: invalid minute"))
    })?;
    if h > 24 || (h == 24 && m > 0) || m > 59 {
        return Err(ParseTimeExprError(format!(
            "{s:?}: out of range (max 24:00)"
        )));
    }
    Ok((h, m))
}

impl FromStr for TimeExpr {
    type Err = ParseTimeExprError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        // Try sun-relative first.
        for (prefix, event) in [("sunrise", SunEvent::Sunrise), ("sunset", SunEvent::Sunset)] {
            if let Some(rest) = s.strip_prefix(prefix) {
                if rest.is_empty() {
                    return Ok(TimeExpr::SunRelative { event, offset_minutes: 0 });
                }
                let (sign, hhmm) = if let Some(hhmm) = rest.strip_prefix('+') {
                    (1i16, hhmm)
                } else if let Some(hhmm) = rest.strip_prefix('-') {
                    (-1i16, hhmm)
                } else {
                    return Err(ParseTimeExprError(format!(
                        "{s:?}: expected +HH:MM or -HH:MM after {prefix}"
                    )));
                };
                let (h, m) = parse_hhmm(hhmm)?;
                let offset = sign * (h as i16 * 60 + m as i16);
                return Ok(TimeExpr::SunRelative { event, offset_minutes: offset });
            }
        }
        // Fixed time.
        let (h, m) = parse_hhmm(s)?;
        Ok(TimeExpr::Fixed { minute_of_day: h as u16 * 60 + m as u16 })
    }
}

// ---- Display ---------------------------------------------------------------

impl fmt::Display for TimeExpr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TimeExpr::Fixed { minute_of_day } => {
                let h = minute_of_day / 60;
                let m = minute_of_day % 60;
                write!(f, "{h:02}:{m:02}")
            }
            TimeExpr::SunRelative { event, offset_minutes } => {
                let name = match event {
                    SunEvent::Sunrise => "sunrise",
                    SunEvent::Sunset => "sunset",
                };
                if *offset_minutes == 0 {
                    write!(f, "{name}")
                } else {
                    let sign = if *offset_minutes > 0 { '+' } else { '-' };
                    let abs = offset_minutes.unsigned_abs();
                    let h = abs / 60;
                    let m = abs % 60;
                    write!(f, "{name}{sign}{h:02}:{m:02}")
                }
            }
        }
    }
}

// ---- Serde (as string) -----------------------------------------------------

impl Serialize for TimeExpr {
    fn serialize<S: ser::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.to_string())
    }
}

impl<'de> Deserialize<'de> for TimeExpr {
    fn deserialize<D: de::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let s = String::deserialize(deserializer)?;
        s.parse().map_err(de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_fixed() {
        assert_eq!("06:00".parse::<TimeExpr>().unwrap(), TimeExpr::Fixed { minute_of_day: 360 });
        assert_eq!("23:00".parse::<TimeExpr>().unwrap(), TimeExpr::Fixed { minute_of_day: 1380 });
        assert_eq!("00:00".parse::<TimeExpr>().unwrap(), TimeExpr::Fixed { minute_of_day: 0 });
        assert_eq!("24:00".parse::<TimeExpr>().unwrap(), TimeExpr::Fixed { minute_of_day: 1440 });
        assert_eq!("12:30".parse::<TimeExpr>().unwrap(), TimeExpr::Fixed { minute_of_day: 750 });
    }

    #[test]
    fn parse_sun_bare() {
        assert_eq!(
            "sunrise".parse::<TimeExpr>().unwrap(),
            TimeExpr::SunRelative { event: SunEvent::Sunrise, offset_minutes: 0 }
        );
        assert_eq!(
            "sunset".parse::<TimeExpr>().unwrap(),
            TimeExpr::SunRelative { event: SunEvent::Sunset, offset_minutes: 0 }
        );
    }

    #[test]
    fn parse_sun_with_offset() {
        assert_eq!(
            "sunset-01:00".parse::<TimeExpr>().unwrap(),
            TimeExpr::SunRelative { event: SunEvent::Sunset, offset_minutes: -60 }
        );
        assert_eq!(
            "sunrise+01:30".parse::<TimeExpr>().unwrap(),
            TimeExpr::SunRelative { event: SunEvent::Sunrise, offset_minutes: 90 }
        );
    }

    #[test]
    fn parse_rejects_invalid() {
        assert!("25:00".parse::<TimeExpr>().is_err());
        assert!("12:60".parse::<TimeExpr>().is_err());
        assert!("sunset*01:00".parse::<TimeExpr>().is_err());
        assert!("noon".parse::<TimeExpr>().is_err());
    }

    #[test]
    fn display_roundtrip() {
        for s in ["06:00", "23:00", "24:00", "00:00", "sunrise", "sunset-01:00", "sunrise+01:30"] {
            let expr: TimeExpr = s.parse().unwrap();
            assert_eq!(expr.to_string(), s);
        }
    }

    #[test]
    fn serde_roundtrip() {
        let expr: TimeExpr = "sunset-01:00".parse().unwrap();
        let json = serde_json::to_string(&expr).unwrap();
        assert_eq!(json, r#""sunset-01:00""#);
        let back: TimeExpr = serde_json::from_str(&json).unwrap();
        assert_eq!(back, expr);
    }

    #[test]
    fn resolve_fixed() {
        let expr = TimeExpr::Fixed { minute_of_day: 360 };
        assert_eq!(expr.resolve(None), 360);
    }

    #[test]
    fn resolve_sun_relative() {
        let sun = SunTimes { sunrise_minute_of_day: 390, sunset_minute_of_day: 1230 };
        let expr = TimeExpr::SunRelative { event: SunEvent::Sunset, offset_minutes: -60 };
        assert_eq!(expr.resolve(Some(&sun)), 1170);
    }

    #[test]
    fn resolve_clamps_to_bounds() {
        let sun = SunTimes { sunrise_minute_of_day: 30, sunset_minute_of_day: 1200 };
        let expr = TimeExpr::SunRelative { event: SunEvent::Sunrise, offset_minutes: -60 };
        assert_eq!(expr.resolve(Some(&sun)), 0); // clamped, not underflow
    }
}
