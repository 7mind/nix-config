//! Runtime trigger / effect types. Mirror the JSON-shaped
//! [`crate::config::bindings::Trigger`] and
//! [`crate::config::bindings::Effect`] enums but reference rooms,
//! devices, and plugs by typed index instead of by string name.
//!
//! The conversion happens once during [`super::Topology::build`];
//! everywhere downstream of topology builds (logic, web, mqtt, daemon)
//! sees only these resolved types.

use std::time::Duration;

use crate::config::switch_model::Gesture;
use crate::config::time_expr::TimeExpr;

use super::{DeviceIdx, PlugIdx, RoomIdx};

/// Event condition that activates a binding. Same variants as
/// [`crate::config::bindings::Trigger`] but with resolved indexes.
#[derive(Debug, Clone)]
pub enum ResolvedTrigger {
    /// Switch button event. `device` is a switch.
    Button {
        device: DeviceIdx,
        button: String,
        gesture: Gesture,
    },
    /// Plug power stayed below `watts` for `holdoff`.
    PowerBelow {
        plug: PlugIdx,
        watts: f64,
        holdoff: Duration,
    },
    /// Time-of-day trigger.
    At {
        time: TimeExpr,
    },
}

impl ResolvedTrigger {
    /// The device this trigger watches, if any (button switch or
    /// power-monitored plug).
    pub fn device(&self) -> Option<DeviceIdx> {
        match self {
            Self::Button { device, .. } => Some(*device),
            Self::PowerBelow { plug, .. } => Some(plug.device()),
            Self::At { .. } => None,
        }
    }
}

/// Command to execute when a trigger fires. Same variants as
/// [`crate::config::bindings::Effect`] but with resolved indexes.
#[derive(Debug, Clone)]
pub enum ResolvedEffect {
    // ---- Room-targeting effects ----
    SceneCycle { room: RoomIdx },
    SceneToggle { room: RoomIdx },
    SceneToggleCycle { room: RoomIdx },
    TurnOffRoom { room: RoomIdx },
    BrightnessStep { room: RoomIdx, step: i16, transition: f64 },
    BrightnessMove { room: RoomIdx, rate: i16 },
    BrightnessStop { room: RoomIdx },

    // ---- Device-targeting effects (always plugs) ----
    Toggle { plug: PlugIdx, confirm_off_seconds: Option<f64> },
    TurnOn { plug: PlugIdx },
    TurnOff { plug: PlugIdx },

    // ---- Global ----
    TurnOffAllZones,
}

impl ResolvedEffect {
    /// The room this effect targets, if it's a room-targeting effect.
    pub fn room(&self) -> Option<RoomIdx> {
        match self {
            Self::SceneCycle { room }
            | Self::SceneToggle { room }
            | Self::SceneToggleCycle { room }
            | Self::TurnOffRoom { room }
            | Self::BrightnessStep { room, .. }
            | Self::BrightnessMove { room, .. }
            | Self::BrightnessStop { room } => Some(*room),
            _ => None,
        }
    }

    /// The plug this effect targets, if it's a device-targeting effect.
    pub fn target_plug(&self) -> Option<PlugIdx> {
        match self {
            Self::Toggle { plug, .. }
            | Self::TurnOn { plug }
            | Self::TurnOff { plug } => Some(*plug),
            _ => None,
        }
    }

    /// For `Toggle` with `confirm_off_seconds`, the confirmation window.
    pub fn confirm_off_seconds(&self) -> Option<f64> {
        match self {
            Self::Toggle { confirm_off_seconds, .. } => *confirm_off_seconds,
            _ => None,
        }
    }
}
