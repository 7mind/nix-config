//! Motion sensor TASS entity. Read-only (no target state).

use crate::tass::{ActualFreshness, TassActual};

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
    /// True only if the sensor is reporting occupied AND the reading
    /// is fresh. A stale occupied sensor (dropped off zigbee) is NOT
    /// treated as occupied — this prevents a dead sensor from keeping
    /// lights on indefinitely.
    pub fn is_occupied(&self) -> bool {
        self.actual.freshness() == ActualFreshness::Fresh
            && self.actual.value().is_some_and(|a| a.occupied)
    }

    pub fn illuminance(&self) -> Option<u32> {
        self.actual.value().and_then(|a| a.illuminance)
    }
}
