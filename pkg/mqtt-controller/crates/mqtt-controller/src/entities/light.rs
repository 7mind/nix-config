//! Per-light target ownership and observed state, shared by group and direct commands.

use crate::tass::{TassActual, TassTarget};

#[derive(Debug, Clone, PartialEq)]
pub enum LightTarget {
    Off,
    On {
        brightness: Option<u8>,
        color_temp: Option<u16>,
    },
}

impl LightTarget {
    pub fn matches(&self, actual: &LightActual) -> bool {
        match self {
            Self::Off => !actual.on,
            Self::On {
                brightness,
                color_temp,
            } => {
                actual.on
                    && brightness.is_none_or(|value| actual.brightness == Some(value))
                    && color_temp.is_none_or(|value| actual.color_temp == Some(value))
            }
        }
    }
}

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
    pub target: TassTarget<LightTarget>,
    pub actual: TassActual<LightActual>,
}

impl Default for LightEntity {
    fn default() -> Self {
        Self {
            target: TassTarget::new(),
            actual: TassActual::new(),
        }
    }
}

impl LightEntity {
    pub fn is_on(&self) -> bool {
        self.actual.value().is_some_and(|a| a.on)
            || matches!(self.target.value(), Some(LightTarget::On { .. }))
    }
}

#[cfg(test)]
#[path = "light_tests.rs"]
mod tests;
