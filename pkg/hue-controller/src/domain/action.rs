//! Actions flowing OUT of the controller. Every state-machine transition
//! returns a `Vec<Action>`; the MQTT bridge serializes each action's
//! `Payload` to JSON and publishes it to the right `zigbee2mqtt/<group>/set`
//! topic.

use serde::Serialize;

/// One thing the controller wants to publish to MQTT.
#[derive(Debug, Clone, PartialEq)]
pub struct Action {
    /// z2m group friendly_name. The MQTT bridge maps this to
    /// `zigbee2mqtt/<group_name>/set`.
    pub group_name: String,

    pub payload: Payload,
}

impl Action {
    pub fn new(group_name: impl Into<String>, payload: Payload) -> Self {
        Self {
            group_name: group_name.into(),
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
}
