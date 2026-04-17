//! TASS entity types and world state container.
//!
//! Each entity holds target+actual state with lifecycle tracking.
//! [`WorldState`] is the complete collection of all entities plus
//! transient event-processing state.

pub mod heating_zone;
pub mod light;
pub mod light_zone;
pub mod motion_sensor;
pub mod plug;
pub mod trv;

use std::collections::BTreeMap;
use std::time::Instant;

pub use heating_zone::{HeatingZoneActual, HeatingZoneEntity, HeatingZoneTarget};
pub use light::{LightActual, LightEntity};
pub use light_zone::{LightZoneActual, LightZoneEntity, LightZoneTarget};
pub use motion_sensor::{MotionActual, MotionSensorEntity};
pub use plug::{KillSwitchRuleState, PlugActual, PlugEntity, PlugTarget};
pub use trv::{ForceOpenReason, HeatingRunningState, TrvActual, TrvEntity, TrvTarget};

/// Deferred button press (for soft/hardware double-tap detection).
#[derive(Debug, Clone)]
pub struct PendingPress {
    pub device: String,
    pub button: String,
    pub ts: Instant,
    pub deadline: Instant,
    /// When true, Press bindings were already dispatched at deferral time
    /// (early-fire optimization for hw-double-tap buttons targeting OFF rooms).
    pub already_fired: bool,
}

/// The complete state of all TASS entities plus transient event-processing state.
#[derive(Debug, Clone)]
pub struct WorldState {
    // --- TASS entities ---
    pub light_zones: BTreeMap<String, LightZoneEntity>,
    pub lights: BTreeMap<String, LightEntity>,
    pub plugs: BTreeMap<String, PlugEntity>,
    pub motion_sensors: BTreeMap<String, MotionSensorEntity>,
    pub heating_zones: BTreeMap<String, HeatingZoneEntity>,
    pub trvs: BTreeMap<String, TrvEntity>,

    // --- Transient event-processing state (not TASS entities) ---

    /// Pending deferred presses, keyed by (device, button).
    pub pending_presses: BTreeMap<(String, String), PendingPress>,
    /// Last hardware double-tap timestamp per (device, button).
    pub last_double_tap: BTreeMap<(String, String), Instant>,
    /// Last (hour, minute) at which each At trigger fired.
    pub at_last_fired: BTreeMap<String, (u8, u8)>,
    /// Confirm-off pending timestamps per binding rule name.
    pub confirm_off_pending: BTreeMap<String, Instant>,
}

impl WorldState {
    pub fn new() -> Self {
        Self {
            light_zones: BTreeMap::new(),
            lights: BTreeMap::new(),
            plugs: BTreeMap::new(),
            motion_sensors: BTreeMap::new(),
            heating_zones: BTreeMap::new(),
            trvs: BTreeMap::new(),
            pending_presses: BTreeMap::new(),
            last_double_tap: BTreeMap::new(),
            at_last_fired: BTreeMap::new(),
            confirm_off_pending: BTreeMap::new(),
        }
    }

    /// Get or create a light zone entity.
    pub fn light_zone(&mut self, name: &str) -> &mut LightZoneEntity {
        self.light_zones
            .entry(name.to_string())
            .or_default()
    }

    /// Get or create an individual light entity.
    pub fn light(&mut self, name: &str) -> &mut LightEntity {
        self.lights.entry(name.to_string()).or_default()
    }

    /// Get or create a plug entity.
    pub fn plug(&mut self, name: &str) -> &mut PlugEntity {
        self.plugs.entry(name.to_string()).or_default()
    }

    /// Get or create a motion sensor entity.
    pub fn motion_sensor(&mut self, name: &str) -> &mut MotionSensorEntity {
        self.motion_sensors
            .entry(name.to_string())
            .or_default()
    }

    /// Get or create a heating zone entity.
    pub fn heating_zone(&mut self, name: &str) -> &mut HeatingZoneEntity {
        self.heating_zones
            .entry(name.to_string())
            .or_default()
    }

    /// Get or create a TRV entity.
    pub fn trv(&mut self, name: &str) -> &mut TrvEntity {
        self.trvs.entry(name.to_string()).or_default()
    }

    /// Earliest pending press deadline, if any.
    pub fn next_press_deadline(&self) -> Option<Instant> {
        self.pending_presses.values().map(|p| p.deadline).min()
    }
}

impl Default for WorldState {
    fn default() -> Self {
        Self::new()
    }
}
