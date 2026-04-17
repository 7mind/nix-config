//! Per-light TASS entity. Read-only actual state (no target).
//!
//! Individual lights inherit commands from their group; no per-light
//! target is emitted. This mirrors [`crate::entities::motion_sensor`]'s
//! actual-only pattern. The frontend uses this so each member light's
//! current brightness/color/on-state is visible inside its zone card.

use crate::tass::TassActual;

/// Fields published by z2m on `zigbee2mqtt/<light>` that we track.
/// All secondary fields are `Option` because z2m's per-device payloads
/// vary by device type (a plain on/off bulb lacks brightness, tunable
/// whites lack `color_xy`, etc.).
#[derive(Debug, Clone, PartialEq)]
pub struct LightActual {
    pub on: bool,
    pub brightness: Option<u8>,
    pub color_temp: Option<u16>,
    pub color_xy: Option<(f64, f64)>,
}

#[derive(Debug, Clone)]
pub struct LightEntity {
    pub actual: TassActual<LightActual>,
}

impl Default for LightEntity {
    fn default() -> Self {
        Self {
            actual: TassActual::new(),
        }
    }
}

impl LightEntity {
    pub fn is_on(&self) -> bool {
        self.actual.value().is_some_and(|a| a.on)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tass::ActualFreshness;
    use std::time::Instant;

    #[test]
    fn default_light_is_off_unknown() {
        let l = LightEntity::default();
        assert!(!l.is_on());
        assert_eq!(l.actual.freshness(), ActualFreshness::Unknown);
    }

    #[test]
    fn update_sets_actual_fresh() {
        let mut l = LightEntity::default();
        let ts = Instant::now();
        l.actual.update(
            LightActual {
                on: true,
                brightness: Some(200),
                color_temp: Some(350),
                color_xy: None,
            },
            ts,
        );
        assert!(l.is_on());
        assert_eq!(l.actual.freshness(), ActualFreshness::Fresh);
        assert_eq!(l.actual.value().unwrap().brightness, Some(200));
    }
}
