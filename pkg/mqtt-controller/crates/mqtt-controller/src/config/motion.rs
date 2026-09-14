//! Motion automation is independent of Zigbee groups.
use super::scenes::SceneSchedule;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum MotionMode {
    #[default]
    OnOff,
    OnOnly,
    OffOnly,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(untagged, deny_unknown_fields)]
pub enum MotionTarget {
    Group { group: String },
    Lights { lights: Vec<String> },
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct MotionRule {
    pub name: String,
    pub sensors: Vec<String>,
    pub mode: MotionMode,
    pub scenes: SceneSchedule,
    pub targets_by_slot: BTreeMap<String, MotionTarget>,
    pub off_transition_seconds: f64,
    pub off_cooldown_seconds: u32,
    pub max_illuminance: Option<u32>,
}
