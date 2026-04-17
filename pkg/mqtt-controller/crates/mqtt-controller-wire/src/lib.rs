//! Shared wire types for the mqtt-controller WebSocket API.
//!
//! This crate defines the JSON message types exchanged between the
//! mqtt-controller daemon's WebSocket server and the Leptos frontend.
//! It depends only on `serde` / `serde_json` so it compiles for both
//! native and `wasm32-unknown-unknown` targets.

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Snapshots (server → client)
// ---------------------------------------------------------------------------

/// TASS target state summary for the frontend.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct TassTargetInfo {
    /// Human-readable target value (e.g. "On(S1)", "Off", "21.0 C").
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub value: String,
    /// Target phase: "unset", "pending", "commanded", "confirmed".
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub phase: String,
    /// Who set the target: "user", "motion", "schedule", "webui", "system", "rule".
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub owner: String,
    /// Milliseconds since the current phase was entered.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since_ago_ms: Option<u64>,
}

/// TASS actual state summary for the frontend.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct TassActualInfo {
    /// Human-readable actual value (e.g. "On", "Off", "20.5 C").
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub value: String,
    /// Actual freshness: "unknown", "fresh", "stale".
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub freshness: String,
    /// Milliseconds since the last reading.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since_ago_ms: Option<u64>,
}

/// Info about a switch that controls a room or plug. Grouped by the
/// physical switch device (one entry per device, not per button).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SwitchInfo {
    pub device: String,
    /// Buttons on this device with actions attached.
    pub buttons: Vec<SwitchButtonInfo>,
}

/// One button on a switch, with all actions bound across gestures.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SwitchButtonInfo {
    pub button: String,
    pub actions: Vec<SwitchActionInfo>,
}

/// One (gesture, effect) action assignment for a switch button.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SwitchActionInfo {
    /// Gesture: "press", "hold", "hold_release", "double_tap", "soft_double_tap".
    pub gesture: String,
    /// Human-readable effect: "scene_cycle: kitchen-cooker", "toggle: z2m-p-printer", etc.
    pub description: String,
}

/// Motion sensor state for the systems view.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MotionSensorInfo {
    pub device: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub occupied: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub illuminance: Option<u32>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub freshness: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since_ago_ms: Option<u64>,
    /// Configured occupancy_timeout for the sensor (seconds before it
    /// will report unoccupied after motion stops).
    #[serde(default, skip_serializing_if = "is_zero_u32")]
    pub occupancy_timeout_secs: u32,
    /// Configured max_illuminance gate (lux), or `None` if unset.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_illuminance: Option<u32>,
}

/// One light in a light zone. Individual light state is not tracked by
/// the backend — lights inherit the zone's aggregate state. This struct
/// exists so the UI can list member devices per zone.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LightInfo {
    pub device: String,
}

/// Kill switch rule state for the systems view.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct KillSwitchRuleInfo {
    pub rule_name: String,
    /// "inactive", "armed", "idle", "suppressed"
    pub state: String,
    pub threshold_watts: f64,
    pub holdoff_secs: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idle_since_ago_ms: Option<u64>,
}

/// Current state of one room. `*_ago_ms` fields are milliseconds elapsed
/// since the corresponding event, relative to
/// [`FullStateSnapshot::timestamp_epoch_ms`].
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RoomSnapshot {
    pub name: String,
    pub group_name: String,
    pub physically_on: bool,
    pub motion_owned: bool,
    pub cycle_idx: usize,
    /// Milliseconds since the last button press, or `None` if never pressed.
    pub last_press_ago_ms: Option<u64>,
    /// Milliseconds since the last OFF transition, or `None` if never off.
    pub last_off_ago_ms: Option<u64>,
    /// Names of motion sensors currently reporting occupancy.
    pub motion_active_sensors: Vec<String>,
    /// Name of the currently active time-of-day slot (e.g. "day", "night").
    pub active_slot: Option<String>,
    /// Scene ids in the active slot's cycle, in order.
    pub scene_ids: Vec<u8>,

    // --- TASS system view fields ---

    /// TASS target state.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<TassTargetInfo>,
    /// TASS actual state.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actual: Option<TassActualInfo>,
    /// Switches bound to this room.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub switches: Vec<SwitchInfo>,
    /// Motion sensors for this room with their current state.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub motion_sensors: Vec<MotionSensorInfo>,
    /// Individual member lights. No per-light state (lights inherit
    /// the zone); this is the device inventory only.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub lights: Vec<LightInfo>,
    /// Configured `motion_off_cooldown_seconds` for the room. 0 = no cooldown.
    #[serde(default, skip_serializing_if = "is_zero_u32")]
    pub motion_off_cooldown_secs: u32,
    /// Remaining seconds of cooldown after the most recent OFF.
    /// `None` once the cooldown has expired (or if no OFF recorded).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub motion_cooldown_remaining_secs: Option<u64>,
}

/// Current state of one smart plug.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlugSnapshot {
    pub device: String,
    pub on: bool,
    /// Milliseconds since the plug entered idle (power below threshold).
    pub idle_since_ago_ms: Option<u64>,
    /// Kill-switch holdoff duration in seconds. When `idle_since_ago_ms`
    /// is `Some`, this is the total holdoff the plug must survive before
    /// being turned off.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kill_switch_holdoff_secs: Option<u64>,
    /// Most recent power reading in watts, if available.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub power_watts: Option<f64>,

    // --- TASS system view fields ---

    /// TASS target state.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<TassTargetInfo>,
    /// TASS actual state.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actual: Option<TassActualInfo>,
    /// Kill switch rules with their current state.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub kill_switch_rules: Vec<KillSwitchRuleInfo>,
    /// Switches that control this plug.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub linked_switches: Vec<SwitchInfo>,
}

/// Current state of one heating zone (relay + TRVs).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HeatingZoneSnapshot {
    pub name: String,
    pub relay_device: String,
    pub relay_on: bool,
    pub relay_state_known: bool,
    pub relay_temperature: Option<f64>,
    pub trvs: Vec<TrvSnapshot>,
    /// Seconds until `min_cycle` allows the pump to stop (0 = not blocked).
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub min_cycle_remaining_secs: u64,
    /// Seconds until `min_pause` allows the pump to start (0 = not blocked).
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub min_pause_remaining_secs: u64,
    /// True if the wall thermostat hasn't reported state recently.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub relay_stale: bool,
}

fn is_zero_u64(v: &u64) -> bool {
    *v == 0
}

fn is_zero_u32(v: &u32) -> bool {
    *v == 0
}

/// Current state of one TRV.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TrvSnapshot {
    pub device: String,
    pub local_temperature: Option<f64>,
    pub pi_heating_demand: Option<u8>,
    /// `"idle"`, `"heat"`, or `"unknown"`.
    pub running_state: String,
    pub setpoint: Option<f64>,
    pub battery: Option<u8>,
    /// True if open-window inhibition is active.
    pub inhibited: bool,
    /// True if the TRV is force-opened (pressure group or min_cycle hold).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub forced: bool,
    /// Name of the temperature schedule driving this TRV.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub schedule: String,
    /// Human-readable schedule summary (today's time ranges).
    /// e.g. `"00:00–06:00 → 21°C, 06:00–23:00 → 18°C, 23:00–24:00 → 21°C"`
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub schedule_summary: String,
}

/// Full state snapshot sent on connect or on explicit request.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FullStateSnapshot {
    pub rooms: Vec<RoomSnapshot>,
    pub plugs: Vec<PlugSnapshot>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub heating_zones: Vec<HeatingZoneSnapshot>,
    /// Wall-clock timestamp of when this snapshot was taken (Unix epoch ms).
    pub timestamp_epoch_ms: u64,
}

// ---------------------------------------------------------------------------
// Decision log (server → client, streaming)
// ---------------------------------------------------------------------------

/// One event + the controller's response. Streamed to clients in real time.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DecisionLogEntry {
    /// Monotonically increasing sequence number.
    pub seq: u64,
    /// Wall-clock timestamp (Unix epoch ms).
    pub timestamp_epoch_ms: u64,
    /// Human-readable summary of the triggering event.
    pub event_summary: String,
    /// Tracing messages captured during `handle_event`.
    pub decisions: Vec<String>,
    /// Actions the controller decided to publish.
    pub actions_emitted: Vec<ActionDto>,
    /// Entity names involved in this event (source + action targets).
    /// Used by the frontend to filter events by entity.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub involved_entities: Vec<String>,
}

/// One outbound action (scene recall, state change, brightness, etc.).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ActionDto {
    /// Friendly name of the target group or device.
    pub target: String,
    /// `"group"` or `"device"`.
    pub target_kind: String,
    /// The raw JSON payload sent to `zigbee2mqtt/<target>/set`.
    pub payload_json: String,
}

// ---------------------------------------------------------------------------
// Topology info (server → client, on connect)
// ---------------------------------------------------------------------------

/// Static topology metadata. Sent once on connect so the frontend knows
/// all rooms, their slots, and available scene ids.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TopologyInfo {
    pub rooms: Vec<RoomInfo>,
    pub plugs: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub heating_zones: Vec<HeatingZoneInfo>,
}

/// Static metadata for one heating zone.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HeatingZoneInfo {
    pub name: String,
    pub relay_device: String,
    pub trv_devices: Vec<String>,
}

/// Static metadata for one room.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RoomInfo {
    pub name: String,
    pub group_name: String,
    pub parent: Option<String>,
    pub slots: Vec<SlotInfo>,
    pub has_motion: bool,
}

/// One time-of-day slot within a room's scene schedule.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SlotInfo {
    pub name: String,
    /// Slot start as a time expression string (e.g. "06:00", "sunset-01:00").
    pub from: String,
    /// Slot end (exclusive) as a time expression string.
    pub to: String,
    pub scene_ids: Vec<u8>,
}

// ---------------------------------------------------------------------------
// Client → Server
// ---------------------------------------------------------------------------

/// Messages the frontend sends to the server over WebSocket.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type")]
pub enum ClientMessage {
    /// Request the current full state snapshot.
    GetState,
    /// Request the static topology info.
    GetTopology,
    /// Recall a specific scene in a room.
    RecallScene { room: String, scene_id: u8 },
    /// Turn a room's lights off.
    SetRoomOff { room: String },
    /// Toggle a smart plug on/off.
    TogglePlug { device: String },
}

// ---------------------------------------------------------------------------
// Server → Client
// ---------------------------------------------------------------------------

/// Messages the server sends to the frontend over WebSocket. All messages
/// are multiplexed on a single connection, discriminated by `type`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type")]
pub enum ServerMessage {
    /// Full state snapshot (response to [`ClientMessage::GetState`]).
    StateSnapshot(FullStateSnapshot),
    /// Static topology (response to [`ClientMessage::GetTopology`]).
    Topology(TopologyInfo),
    /// Real-time event + decision log entry.
    EventLog(DecisionLogEntry),
    /// Incremental room state update (after any event that changes a room).
    RoomUpdate(RoomSnapshot),
    /// Incremental plug state update.
    PlugUpdate(PlugSnapshot),
    /// Incremental heating zone state update.
    HeatingZoneUpdate(HeatingZoneSnapshot),
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn client_message_round_trip() {
        let msgs = vec![
            ClientMessage::GetState,
            ClientMessage::GetTopology,
            ClientMessage::RecallScene {
                room: "kitchen".into(),
                scene_id: 3,
            },
            ClientMessage::SetRoomOff {
                room: "bedroom".into(),
            },
            ClientMessage::TogglePlug {
                device: "z2m-p-printer".into(),
            },
        ];
        for msg in &msgs {
            let json = serde_json::to_string(msg).unwrap();
            let back: ClientMessage = serde_json::from_str(&json).unwrap();
            assert_eq!(msg, &back);
        }
    }

    #[test]
    fn server_message_round_trip() {
        let snapshot = ServerMessage::StateSnapshot(FullStateSnapshot {
            rooms: vec![RoomSnapshot {
                name: "kitchen".into(),
                group_name: "hue-lz-kitchen".into(),
                physically_on: true,
                motion_owned: false,
                cycle_idx: 1,
                last_press_ago_ms: Some(5000),
                last_off_ago_ms: None,
                motion_active_sensors: vec!["hue-ms-kitchen".into()],
                active_slot: Some("day".into()),
                scene_ids: vec![1, 2, 3],
                target: None,
                actual: None,
                switches: vec![],
                motion_sensors: vec![],
                lights: vec![],
                motion_off_cooldown_secs: 0,
                motion_cooldown_remaining_secs: None,
            }],
            plugs: vec![PlugSnapshot {
                device: "z2m-p-printer".into(),
                on: true,
                idle_since_ago_ms: Some(30000),
                kill_switch_holdoff_secs: Some(600),
                power_watts: Some(120.5),
                target: None,
                actual: None,
                kill_switch_rules: vec![],
                linked_switches: vec![],
            }],
            heating_zones: vec![HeatingZoneSnapshot {
                name: "living-room".into(),
                relay_device: "z2m-wt-living".into(),
                relay_on: true,
                relay_state_known: true,
                relay_temperature: Some(21.5),
                trvs: vec![TrvSnapshot {
                    device: "z2m-trv-living-1".into(),
                    local_temperature: Some(20.8),
                    pi_heating_demand: Some(60),
                    running_state: "heat".into(),
                    setpoint: Some(22.0),
                    battery: Some(85),
                    inhibited: false,
                    forced: false,
                    schedule: "living".into(),
                    schedule_summary: "00:00\u{2013}07:00 \u{2192} 18\u{00b0}C, 07:00\u{2013}22:00 \u{2192} 21\u{00b0}C, 22:00\u{2013}24:00 \u{2192} 18\u{00b0}C".into(),
                }],
                min_cycle_remaining_secs: 0,
                min_pause_remaining_secs: 0,
                relay_stale: false,
            }],
            timestamp_epoch_ms: 1700000000000,
        });
        let json = serde_json::to_string(&snapshot).unwrap();
        let back: ServerMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(snapshot, back);
    }

    #[test]
    fn server_message_topology_round_trip() {
        let topo = ServerMessage::Topology(TopologyInfo {
            rooms: vec![RoomInfo {
                name: "study".into(),
                group_name: "hue-lz-study".into(),
                parent: None,
                slots: vec![SlotInfo {
                    name: "day".into(),
                    from: "07:00".into(),
                    to: "22:00".into(),
                    scene_ids: vec![1, 2],
                }],
                has_motion: true,
            }],
            plugs: vec!["z2m-p-printer".into()],
            heating_zones: vec![HeatingZoneInfo {
                name: "study".into(),
                relay_device: "z2m-wt-study".into(),
                trv_devices: vec!["z2m-trv-study-1".into()],
            }],
        });
        let json = serde_json::to_string(&topo).unwrap();
        let back: ServerMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(topo, back);
    }

    #[test]
    fn event_log_round_trip() {
        let entry = ServerMessage::EventLog(DecisionLogEntry {
            seq: 42,
            timestamp_epoch_ms: 1700000000000,
            event_summary: "tap press_2 on hue-ts-kitchen".into(),
            decisions: vec![
                "kitchen-cooker: tap cycle → scene 2".into(),
                "kitchen-cooker: propagate ON to descendants".into(),
            ],
            actions_emitted: vec![ActionDto {
                target: "hue-lz-kitchen-cooker".into(),
                target_kind: "group".into(),
                payload_json: r#"{"scene_recall":2}"#.into(),
            }],
            involved_entities: vec![
                "hue-lz-kitchen-cooker".into(),
                "hue-ts-kitchen".into(),
                "kitchen-cooker".into(),
            ],
        });
        let json = serde_json::to_string(&entry).unwrap();
        let back: ServerMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(entry, back);
    }

    #[test]
    fn client_message_has_type_tag() {
        let json = serde_json::to_string(&ClientMessage::GetState).unwrap();
        assert!(json.contains(r#""type":"GetState""#));

        let json =
            serde_json::to_string(&ClientMessage::RecallScene {
                room: "x".into(),
                scene_id: 1,
            })
            .unwrap();
        assert!(json.contains(r#""type":"RecallScene""#));
        assert!(json.contains(r#""room":"x""#));
    }

    #[test]
    fn server_message_has_type_tag() {
        let json = serde_json::to_string(&ServerMessage::RoomUpdate(RoomSnapshot {
            name: "x".into(),
            group_name: "g".into(),
            physically_on: false,
            motion_owned: false,
            cycle_idx: 0,
            last_press_ago_ms: None,
            last_off_ago_ms: None,
            motion_active_sensors: vec![],
            target: None,
            actual: None,
            switches: vec![],
            motion_sensors: vec![],
            lights: vec![],
            motion_off_cooldown_secs: 0,
            motion_cooldown_remaining_secs: None,
            active_slot: None,
            scene_ids: vec![],
        }))
        .unwrap();
        assert!(json.contains(r#""type":"RoomUpdate""#));
    }
}
