//! Time expression: either a fixed `HH:MM`, a sun-relative
//! `sunrise/sunset ± HH:MM`, or `max(a, b)` / `min(a, b)` of two
//! sub-expressions.
//!
//! Parsed from a string in the JSON config. Examples:
//!   - `"06:00"`                          → Fixed 06:00
//!   - `"23:00"`                          → Fixed 23:00
//!   - `"24:00"`                          → Fixed 24:00 (exclusive end-of-day sentinel)
//!   - `"sunset"`                         → Sun-relative, sunset + 0
//!   - `"sunset-01:00"`                   → Sun-relative, sunset − 60 min
//!   - `"sunrise+01:30"`                  → Sun-relative, sunrise + 90 min
//!   - `"max(sunset+01:00, 23:00)"`       → The later of two times
//!   - `"min(sunrise-01:00, 05:00)"`      → The earlier of two times

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
    /// The maximum (later) of two sub-expressions.
    Max(Box<TimeExpr>, Box<TimeExpr>),
    /// The minimum (earlier) of two sub-expressions.
    Min(Box<TimeExpr>, Box<TimeExpr>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SunEvent {
    Sunrise,
    Sunset,
}

impl TimeExpr {
    /// Resolve to minutes-since-midnight (0..=1440). For `Fixed`, returns
    /// the stored value directly. For `SunRelative`, computes base + offset
    /// using the provided sun times. For `Max`/`Min`, resolves both operands
    /// and returns the later/earlier.
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
            TimeExpr::Max(a, b) => a.resolve(sun).max(b.resolve(sun)),
            TimeExpr::Min(a, b) => a.resolve(sun).min(b.resolve(sun)),
        }
    }

    /// True if this expression depends on solar position.
    pub fn uses_sun(&self) -> bool {
        match self {
            TimeExpr::Fixed { .. } => false,
            TimeExpr::SunRelative { .. } => true,
            TimeExpr::Max(a, b) | TimeExpr::Min(a, b) => a.uses_sun() || b.uses_sun(),
        }
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

/// Parse a single atomic time expression (fixed or sun-relative, no max/min).
fn parse_atom(s: &str) -> Result<TimeExpr, ParseTimeExprError> {
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
    let (h, m) = parse_hhmm(s)?;
    Ok(TimeExpr::Fixed { minute_of_day: h as u16 * 60 + m as u16 })
}

/// Parse `max(a, b)` or `min(a, b)`. Returns `None` if the string doesn't
/// start with `max(` or `min(`.
fn parse_minmax(s: &str) -> Option<Result<TimeExpr, ParseTimeExprError>> {
    let (func, rest) = if let Some(rest) = s.strip_prefix("max(") {
        ("max", rest)
    } else if let Some(rest) = s.strip_prefix("min(") {
        ("min", rest)
    } else {
        return None;
    };

    let inner = match rest.strip_suffix(')') {
        Some(inner) => inner,
        None => return Some(Err(ParseTimeExprError(format!(
            "{s:?}: missing closing parenthesis"
        )))),
    };

    // Split on ", " (comma + space). Both operands are atoms (no nesting).
    let (left, right) = match inner.split_once(", ") {
        Some(pair) => pair,
        None => return Some(Err(ParseTimeExprError(format!(
            "{s:?}: expected two comma-separated arguments inside {func}()"
        )))),
    };

    let left = match left.trim().parse::<TimeExpr>() {
        Ok(e) => e,
        Err(e) => return Some(Err(e)),
    };
    let right = match right.trim().parse::<TimeExpr>() {
        Ok(e) => e,
        Err(e) => return Some(Err(e)),
    };

    Some(Ok(match func {
        "max" => TimeExpr::Max(Box::new(left), Box::new(right)),
        "min" => TimeExpr::Min(Box::new(left), Box::new(right)),
        _ => unreachable!(),
    }))
}

impl FromStr for TimeExpr {
    type Err = ParseTimeExprError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        // Try max/min wrapper first.
        if let Some(result) = parse_minmax(s) {
            return result;
        }
        // Atom: fixed or sun-relative.
        parse_atom(s)
    }
}

// ---- Display ---------------------------------------------------------------

fn fmt_atom(f: &mut fmt::Formatter<'_>, expr: &TimeExpr) -> fmt::Result {
    match expr {
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
        // Max/Min are handled by the main Display impl, not here.
        TimeExpr::Max(_, _) | TimeExpr::Min(_, _) => {
            write!(f, "{expr}")
        }
    }
}

impl fmt::Display for TimeExpr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TimeExpr::Max(a, b) => {
                write!(f, "max(")?;
                fmt_atom(f, a)?;
                write!(f, ", ")?;
                fmt_atom(f, b)?;
                write!(f, ")")
            }
            TimeExpr::Min(a, b) => {
                write!(f, "min(")?;
                fmt_atom(f, a)?;
                write!(f, ", ")?;
                fmt_atom(f, b)?;
                write!(f, ")")
            }
            other => fmt_atom(f, other),
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
    fn parse_max() {
        let expr = "max(sunset+01:00, 23:00)".parse::<TimeExpr>().unwrap();
        assert_eq!(
            expr,
            TimeExpr::Max(
                Box::new(TimeExpr::SunRelative { event: SunEvent::Sunset, offset_minutes: 60 }),
                Box::new(TimeExpr::Fixed { minute_of_day: 1380 }),
            )
        );
    }

    #[test]
    fn parse_min() {
        let expr = "min(sunrise-01:00, 05:00)".parse::<TimeExpr>().unwrap();
        assert_eq!(
            expr,
            TimeExpr::Min(
                Box::new(TimeExpr::SunRelative { event: SunEvent::Sunrise, offset_minutes: -60 }),
                Box::new(TimeExpr::Fixed { minute_of_day: 300 }),
            )
        );
    }

    #[test]
    fn parse_rejects_invalid() {
        assert!("25:00".parse::<TimeExpr>().is_err());
        assert!("12:60".parse::<TimeExpr>().is_err());
        assert!("sunset*01:00".parse::<TimeExpr>().is_err());
        assert!("noon".parse::<TimeExpr>().is_err());
        assert!("max(23:00)".parse::<TimeExpr>().is_err()); // missing second arg
        assert!("max(23:00, ".parse::<TimeExpr>().is_err()); // missing closing paren
    }

    #[test]
    fn display_roundtrip() {
        for s in [
            "06:00", "23:00", "24:00", "00:00",
            "sunrise", "sunset-01:00", "sunrise+01:30",
            "max(sunset+01:00, 23:00)", "min(sunrise-01:00, 05:00)",
        ] {
            let expr: TimeExpr = s.parse().unwrap();
            assert_eq!(expr.to_string(), s, "display roundtrip failed for {s}");
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
    fn serde_roundtrip_max() {
        let expr: TimeExpr = "max(sunset+01:00, 23:00)".parse().unwrap();
        let json = serde_json::to_string(&expr).unwrap();
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

    #[test]
    fn resolve_max_picks_later() {
        // Summer: sunset at 22:10 (1330), +1h = 23:10 (1390)
        // max(sunset+01:00, 23:00) = max(1390, 1380) = 1390
        let sun = SunTimes { sunrise_minute_of_day: 260, sunset_minute_of_day: 1330 };
        let expr: TimeExpr = "max(sunset+01:00, 23:00)".parse().unwrap();
        assert_eq!(expr.resolve(Some(&sun)), 1390);

        // Winter: sunset at 16:30 (990), +1h = 17:30 (1050)
        // max(sunset+01:00, 23:00) = max(1050, 1380) = 1380
        let sun = SunTimes { sunrise_minute_of_day: 530, sunset_minute_of_day: 990 };
        assert_eq!(expr.resolve(Some(&sun)), 1380);
    }

    #[test]
    fn resolve_min_picks_earlier() {
        // Summer: sunrise at 04:20 (260), -1h = 03:20 (200)
        // min(sunrise-01:00, 05:00) = min(200, 300) = 200
        let sun = SunTimes { sunrise_minute_of_day: 260, sunset_minute_of_day: 1330 };
        let expr: TimeExpr = "min(sunrise-01:00, 05:00)".parse().unwrap();
        assert_eq!(expr.resolve(Some(&sun)), 200);

        // Winter: sunrise at 08:50 (530), -1h = 07:50 (470)
        // min(sunrise-01:00, 05:00) = min(470, 300) = 300
        let sun = SunTimes { sunrise_minute_of_day: 530, sunset_minute_of_day: 990 };
        assert_eq!(expr.resolve(Some(&sun)), 300);
    }

    #[test]
    fn uses_sun_propagates_through_max_min() {
        let fixed: TimeExpr = "23:00".parse().unwrap();
        assert!(!fixed.uses_sun());

        let sun_expr: TimeExpr = "sunset+01:00".parse().unwrap();
        assert!(sun_expr.uses_sun());

        let max_expr: TimeExpr = "max(sunset+01:00, 23:00)".parse().unwrap();
        assert!(max_expr.uses_sun());

        let min_fixed: TimeExpr = "min(05:00, 06:00)".parse().unwrap();
        assert!(!min_fixed.uses_sun());
    }
}
