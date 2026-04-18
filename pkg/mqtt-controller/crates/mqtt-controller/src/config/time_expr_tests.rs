//! Tests for `time_expr`. Split out so `time_expr.rs` stays focused on
//! production code. See `time_expr.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

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
