//! Actions flowing OUT of the controller. Every state-machine transition
//! returns a `Vec<Action>`; the MQTT bridge serializes each action's
//! `Payload` to JSON and publishes it to the right `zigbee2mqtt/<group>/set`
//! topic.

use serde::Serialize;

/// Where to publish an action: a z2m group or a specific device.
#[derive(Debug, Clone, PartialEq)]
pub enum ActionTarget {
    /// Publish to `zigbee2mqtt/<group_name>/set`.
    Group(String),
    /// Publish to `zigbee2mqtt/<device_name>/set`.
    Device(String),
    /// Publish to `zigbee2mqtt/<device_name>/get` — request fresh state.
    DeviceGet(String),
}

/// One thing the controller wants to publish to MQTT.
#[derive(Debug, Clone, PartialEq)]
pub struct Action {
    pub target: ActionTarget,
    pub payload: Payload,
}

impl Action {
    /// Construct a group-targeted action (the common case for room
    /// scene cycling).
    pub fn new(group_name: impl Into<String>, payload: Payload) -> Self {
        Self {
            target: ActionTarget::Group(group_name.into()),
            payload,
        }
    }

    /// Construct a device-targeted action (for smart plugs).
    pub fn for_device(device_name: impl Into<String>, payload: Payload) -> Self {
        Self {
            target: ActionTarget::Device(device_name.into()),
            payload,
        }
    }

    /// The friendly_name to publish to, regardless of target kind.
    /// Used by the MQTT bridge to build the topic.
    pub fn target_name(&self) -> &str {
        match &self.target {
            ActionTarget::Group(name)
            | ActionTarget::Device(name)
            | ActionTarget::DeviceGet(name) => name,
        }
    }

    /// Construct a device GET action (request fresh state from device).
    pub fn get_device_state(device_name: impl Into<String>, payload: Payload) -> Self {
        Self {
            target: ActionTarget::DeviceGet(device_name.into()),
            payload,
        }
    }
}

/// One JSON body to publish on a `/set` topic. Each variant serializes to
/// the exact JSON shape z2m expects — same shapes the bento rules emit.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(untagged)]
pub enum Payload {
    /// `{"scene_recall": N}` — recall a numbered scene on this group.
    SceneRecall { scene_recall: u8 },

    /// `{"state": "OFF", "transition": T}` — turn the group off with a
    /// fade. The state field is a fixed string so it serializes as a
    /// JSON string literal, not an enum tag.
    StateOff {
        state: &'static str,
        transition: f64,
    },

    /// `{"brightness_step": ±N, "transition": T}` — relative brightness
    /// step (issued on up/down press release).
    BrightnessStep {
        brightness_step: i16,
        transition: f64,
    },

    /// `{"brightness_move": ±rate}` — continuous brightness adjust
    /// (issued on up/down hold). `0` stops the move.
    BrightnessMove { brightness_move: i16 },

    /// `{"state": "ON"}` or `{"state": "OFF"}` — simple on/off for
    /// smart plugs and wall thermostat relays. Unlike `StateOff` this
    /// has no transition field.
    DeviceStateSet { state: &'static str },

    /// `{"occupied_heating_setpoint": 22.0}` — set target temperature
    /// on a TRV. Used by the heating controller for schedule-driven
    /// setpoint changes and pressure group force-open.
    TrvSetpoint { occupied_heating_setpoint: f64 },

    /// `{"operating_mode": "manual"}` — reassert the required operating
    /// mode on a TRV or wall thermostat that has drifted (e.g. someone
    /// pressed a button on the physical device).
    OperatingMode { operating_mode: &'static str },

    /// `{"window_detection": "ON"}` or `{"window_detection": "OFF"}` —
    /// Bosch BTH-RA/RM230Z window-open mode. When ON, the device stops
    /// all heating and resumes cleanly when set back to OFF (no setpoint
    /// manipulation needed).
    WindowDetection { window_detection: &'static str },

    /// `{"state": ""}` — request fresh state from a device via `/get`.
    /// Used by wall thermostat keepalive to detect offline devices.
    GetState { state: &'static str },
}

impl Payload {
    pub fn scene_recall(id: u8) -> Self {
        Self::SceneRecall { scene_recall: id }
    }

    pub fn state_off(transition: f64) -> Self {
        Self::StateOff {
            state: "OFF",
            transition,
        }
    }

    pub fn brightness_step(step: i16, transition: f64) -> Self {
        Self::BrightnessStep {
            brightness_step: step,
            transition,
        }
    }

    pub fn brightness_move(rate: i16) -> Self {
        Self::BrightnessMove {
            brightness_move: rate,
        }
    }

    pub fn device_on() -> Self {
        Self::DeviceStateSet { state: "ON" }
    }

    pub fn device_off() -> Self {
        Self::DeviceStateSet { state: "OFF" }
    }

    pub fn trv_setpoint(temp: f64) -> Self {
        Self::TrvSetpoint {
            occupied_heating_setpoint: temp,
        }
    }

    pub fn window_detection_on() -> Self {
        Self::WindowDetection {
            window_detection: "ON",
        }
    }

    pub fn window_detection_off() -> Self {
        Self::WindowDetection {
            window_detection: "OFF",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn scene_recall_serializes_to_z2m_shape() {
        let p = Payload::scene_recall(1);
        let json = serde_json::to_string(&p).unwrap();
        assert_eq!(json, r#"{"scene_recall":1}"#);
    }

    #[test]
    fn state_off_serializes_with_uppercase_state() {
        let p = Payload::state_off(0.8);
        let json = serde_json::to_string(&p).unwrap();
        assert_eq!(json, r#"{"state":"OFF","transition":0.8}"#);
    }

    #[test]
    fn brightness_step_serializes_negative() {
        let p = Payload::brightness_step(-25, 0.2);
        let json = serde_json::to_string(&p).unwrap();
        assert_eq!(json, r#"{"brightness_step":-25,"transition":0.2}"#);
    }

    #[test]
    fn brightness_move_zero_stops_move() {
        let p = Payload::brightness_move(0);
        let json = serde_json::to_string(&p).unwrap();
        assert_eq!(json, r#"{"brightness_move":0}"#);
    }

    #[test]
    fn device_state_on_serializes() {
        let p = Payload::device_on();
        let json = serde_json::to_string(&p).unwrap();
        assert_eq!(json, r#"{"state":"ON"}"#);
    }

    #[test]
    fn device_state_off_serializes() {
        let p = Payload::device_off();
        let json = serde_json::to_string(&p).unwrap();
        assert_eq!(json, r#"{"state":"OFF"}"#);
    }

    #[test]
    fn action_target_name_group() {
        let a = Action::new("hue-lz-kitchen", Payload::scene_recall(1));
        assert_eq!(a.target_name(), "hue-lz-kitchen");
        assert!(matches!(a.target, ActionTarget::Group(_)));
    }

    #[test]
    fn action_target_name_device() {
        let a = Action::for_device("z2m-p-printer", Payload::device_on());
        assert_eq!(a.target_name(), "z2m-p-printer");
        assert!(matches!(a.target, ActionTarget::Device(_)));
    }
}
