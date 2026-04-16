//! Topology validation errors. Surfaced as the daemon's startup error
//! when [`super::Topology::build`] rejects a config.

use thiserror::Error;

use super::{FriendlyName, RoomName};

/// All the validation failures the topology builder can produce. Surfaced
/// as the daemon's startup error.
#[derive(Debug, Error, PartialEq)]
pub enum TopologyError {
    #[error("duplicate room name {0:?}")]
    DuplicateRoomName(RoomName),

    #[error("duplicate group id {id} (used by rooms {first:?} and {second:?})")]
    DuplicateGroupId {
        id: u8,
        first: RoomName,
        second: RoomName,
    },

    #[error("duplicate group friendly name {name:?} (used by rooms {first:?} and {second:?})")]
    DuplicateGroupName {
        name: FriendlyName,
        first: RoomName,
        second: RoomName,
    },

    #[error(
        "group name {group_name:?} (room {room:?}) collides with a {device_kind} in the \
         device catalog — both would share the same zigbee2mqtt/<name> MQTT topic"
    )]
    GroupNameDeviceCollision {
        group_name: FriendlyName,
        room: RoomName,
        device_kind: &'static str,
    },

    #[error("room {room:?} has parent {parent:?} which is not a known room")]
    UnknownParent { room: RoomName, parent: RoomName },

    #[error("room {0:?} lists itself as parent")]
    SelfParent(RoomName),

    #[error("parent chain cycle: {chain}")]
    ParentChainCycle { chain: String },

    #[error("room {room:?} references motion sensor {sensor:?} which is not in the device catalog")]
    MotionSensorNotInCatalog {
        room: RoomName,
        sensor: FriendlyName,
    },

    #[error(
        "room {room:?} references motion sensor {sensor:?} but it is a {kind} \
         (expected motion-sensor)"
    )]
    MotionSensorWrongKind {
        room: RoomName,
        sensor: FriendlyName,
        kind: &'static str,
    },

    #[error(
        "room {room:?} member {member:?} references friendly name {bulb:?} which is \
         not a `light` in the catalog"
    )]
    UnknownMemberLight {
        room: RoomName,
        member: String,
        bulb: FriendlyName,
    },

    #[error(
        "room {room:?} member {member:?} is not in the form 'friendly_name/endpoint'"
    )]
    MalformedMember { room: RoomName, member: String },

    #[error(
        "scene schedule for room {room:?} is invalid: {source}"
    )]
    InvalidSceneSchedule {
        room: RoomName,
        #[source]
        source: crate::config::scenes::SceneScheduleError,
    },

    #[error("sun-relative schedule expressions require a `location` in the config")]
    MissingLocationForSunExpressions,

    #[error("duplicate binding name {0:?}")]
    DuplicateBindingName(String),

    #[error(
        "binding {binding:?} trigger references device {device:?} which is not in the catalog"
    )]
    BindingTriggerUnknownDevice { binding: String, device: String },

    #[error(
        "binding {binding:?} trigger requires a switch device \
         but {device:?} is a {actual_kind}"
    )]
    BindingTriggerWrongDeviceKind {
        binding: String,
        device: String,
        actual_kind: &'static str,
    },

    #[error(
        "binding {binding:?} references button {button:?} on device {device:?} \
         (model {model:?}) which does not have that button"
    )]
    BindingButtonNotInModel {
        binding: String,
        device: String,
        model: String,
        button: String,
    },

    #[error(
        "binding {binding:?} references room {room:?} which is not defined"
    )]
    BindingRoomNotFound { binding: String, room: String },

    #[error(
        "binding {binding:?} effect targets device {device:?} which is not in the catalog"
    )]
    BindingEffectUnknownDevice { binding: String, device: String },

    #[error(
        "binding {binding:?} effect targets device {device:?} which is a {kind} \
         (only plugs can be binding targets)"
    )]
    BindingEffectNotPlug { binding: String, device: String, kind: &'static str },

    #[error(
        "binding {binding:?} uses power_below trigger on device {device:?} which \
         lacks the \"power\" capability (variant: {variant})"
    )]
    BindingPowerBelowWithoutCapability {
        binding: String,
        device: String,
        variant: String,
    },

    #[error(
        "binding {binding:?} has power_below trigger on device {trigger_device:?} but \
         effect targets device {effect_target:?} — kill-switch rules must target the \
         same plug they monitor"
    )]
    PowerBelowCrossTarget {
        binding: String,
        trigger_device: String,
        effect_target: String,
    },

    #[error(
        "room {room:?} has negative off_transition_seconds: {value}"
    )]
    NegativeTransition { room: RoomName, value: f64 },

    #[error(
        "defaults.cycle_window_seconds is negative: {0}"
    )]
    NegativeCycleWindow(f64),

    #[error(
        "defaults.double_tap_suppression_seconds is negative: {0}"
    )]
    NegativeDoubleTapSuppression(f64),

    #[error(
        "binding {binding:?} has confirm_off_seconds negative: {value}"
    )]
    NegativeConfirmOffWindow { binding: String, value: f64 },

    #[error(
        "binding {binding:?} has At trigger with invalid time: {time}"
    )]
    InvalidAtTime { binding: String, time: String },

    #[error(
        "plug {device:?} has protocol zwave but no node_id"
    )]
    ZwavePlugMissingNodeId {
        device: FriendlyName,
    },

    #[error(
        "duplicate zwave node_id {node_id} (used by plugs {first:?} and {second:?})"
    )]
    DuplicateZwaveNodeId {
        node_id: u16,
        first: FriendlyName,
        second: FriendlyName,
    },

    #[error(
        "switch device {device:?} references unknown model {model:?}"
    )]
    UnknownSwitchModel {
        device: FriendlyName,
        model: String,
    },

    #[error("heating config error: {0}")]
    HeatingError(#[from] crate::config::heating::HeatingConfigError),
}
