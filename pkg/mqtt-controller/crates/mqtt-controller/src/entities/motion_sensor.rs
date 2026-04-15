//! Motion sensor TASS entity. Read-only (no target state).

use crate::tass::TassActual;

#[derive(Debug, Clone, PartialEq)]
pub struct MotionActual {
    pub occupied: bool,
    pub illuminance: Option<u32>,
}

/// A read-only motion sensor. No target state — sensors are not controllable.
#[derive(Debug, Clone)]
pub struct MotionSensorEntity {
    pub actual: TassActual<MotionActual>,
}

impl Default for MotionSensorEntity {
    fn default() -> Self {
        Self {
            actual: TassActual::new(),
        }
    }
}

impl MotionSensorEntity {
    pub fn is_occupied(&self) -> bool {
        self.actual.value().is_some_and(|a| a.occupied)
    }

    pub fn illuminance(&self) -> Option<u32> {
        self.actual.value().and_then(|a| a.illuminance)
    }
}
