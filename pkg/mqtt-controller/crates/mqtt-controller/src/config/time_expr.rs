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
#[path = "time_expr_tests.rs"]
mod tests;
