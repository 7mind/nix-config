//! Events flowing into the controller. Every MQTT message that the
//! controller cares about is parsed into one of these variants by the
//! [`crate::mqtt`] bridge before reaching the state machine.

use std::time::Instant;

use crate::config::switch_model::Gesture;

/// One discrete input event from the outside world. Wraps everything in
/// a single sum type so the controller's `handle_event` is one big match.
#[derive(Debug, Clone)]
pub enum Event {
    /// A switch button was pressed/held/released/double-tapped. Unified
    /// replacement for the old `SwitchAction` and `TapAction` variants.
    /// The MQTT bridge resolves raw z2m action strings to semantic
    /// `(button, gesture)` pairs using the device's model descriptor.
    ButtonPress {
        device: String,
        button: String,
        gesture: Gesture,
        ts: Instant,
    },

    /// A Hue motion sensor reported an occupancy update.
    Occupancy {
        sensor: String,
        occupied: bool,
        illuminance: Option<u32>,
        ts: Instant,
    },

    /// z2m published a state update for a group we subscribe to. The
    /// controller uses this as ground truth for `physically_on` and
    /// reconciles its internal state machine accordingly.
    GroupState {
        group: String,
        on: bool,
        ts: Instant,
    },

    /// z2m published a state update for a smart plug we subscribe to.
    /// Carries the on/off state and, if the plug supports power
    /// monitoring, the real-time power reading in watts.
    PlugState {
        device: String,
        on: bool,
        /// Real-time power in watts. `None` if the plug doesn't expose
        /// power monitoring or the field was absent from the payload.
        power: Option<f64>,
        ts: Instant,
    },

    /// A Z-Wave plug's meter reported a power update without an
    /// accompanying on/off state change. Z-Wave JS UI publishes state
    /// and power on separate MQTT topics, so power-only updates arrive
    /// independently. The controller updates the plug's power reading
    /// without touching its on/off tracking.
    PlugPowerUpdate {
        device: String,
        /// Real-time power in watts.
        watts: f64,
        ts: Instant,
    },

    /// A TRV (thermostatic radiator valve) reported a state update.
    /// Fields are optional because z2m may publish partial updates.
    TrvState {
        device: String,
        local_temperature: Option<f64>,
        pi_heating_demand: Option<u8>,
        /// `"idle"` or `"heat"`.
        running_state: Option<String>,
        occupied_heating_setpoint: Option<f64>,
        /// `"schedule"`, `"manual"`, or `"pause"`.
        operating_mode: Option<String>,
        /// Battery percentage (0-100).
        battery: Option<u8>,
        ts: Instant,
    },

    /// A wall thermostat (used as relay) reported a state update.
    WallThermostatState {
        device: String,
        /// Relay on/off from the `"state"` JSON field.
        relay_on: Option<bool>,
        local_temperature: Option<f64>,
        /// `"schedule"`, `"manual"`, or `"pause"`.
        operating_mode: Option<String>,
        ts: Instant,
    },

    /// Periodic tick event fired by the daemon's timer. The controller
    /// uses this to evaluate time-dependent action triggers (kill
    /// switch holdoff deadlines) and heating schedule/relay decisions.
    Tick {
        ts: Instant,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn button_press_event_roundtrip() {
        let event = Event::ButtonPress {
            device: "hue-s-kitchen".into(),
            button: "on".into(),
            gesture: Gesture::Press,
            ts: Instant::now(),
        };
        match event {
            Event::ButtonPress { device, button, gesture, .. } => {
                assert_eq!(device, "hue-s-kitchen");
                assert_eq!(button, "on");
                assert_eq!(gesture, Gesture::Press);
            }
            _ => panic!("expected ButtonPress"),
        }
    }
}
