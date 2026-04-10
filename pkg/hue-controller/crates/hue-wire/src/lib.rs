//! Shared wire types for the hue-controller WebSocket API.
//!
//! This crate defines the JSON message types exchanged between the
//! hue-controller daemon's WebSocket server and the Leptos frontend.
//! It depends only on `serde` / `serde_json` so it compiles for both
//! native and `wasm32-unknown-unknown` targets.

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Snapshots (server → client)
// ---------------------------------------------------------------------------

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
}

/// Current state of one smart plug.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlugSnapshot {
    pub device: String,
    pub on: bool,
    /// Milliseconds since the plug entered idle (power below threshold).
    pub idle_since_ago_ms: Option<u64>,
    /// Most recent power reading in watts, if available.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub power_watts: Option<f64>,
}

/// Full state snapshot sent on connect or on explicit request.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FullStateSnapshot {
    pub rooms: Vec<RoomSnapshot>,
    pub plugs: Vec<PlugSnapshot>,
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
    pub start_hour: u8,
    pub end_hour_exclusive: u8,
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
            }],
            plugs: vec![PlugSnapshot {
                device: "z2m-p-printer".into(),
                on: true,
                idle_since_ago_ms: Some(30000),
                power_watts: Some(120.5),
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
                    start_hour: 7,
                    end_hour_exclusive: 22,
                    scene_ids: vec![1, 2],
                }],
                has_motion: true,
            }],
            plugs: vec!["z2m-p-printer".into()],
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
            active_slot: None,
            scene_ids: vec![],
        }))
        .unwrap();
        assert!(json.contains(r#""type":"RoomUpdate""#));
    }
}
