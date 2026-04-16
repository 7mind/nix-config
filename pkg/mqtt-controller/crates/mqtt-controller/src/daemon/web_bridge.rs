//! WebSocket command handling and outbound state broadcasts. Used only
//! when the daemon is started with a [`WebHandle`].

use std::time::Instant;

use tokio::sync::{broadcast, mpsc};

use crate::logic::EventProcessor;
use crate::mqtt::MqttBridge;
use crate::time::Clock;
use crate::web::server::WsCommand;
use crate::web::snapshot;

/// Receive a command from the WebSocket channel if present. Returns
/// `future::pending()` if there is no web handle, so the `select!`
/// branch is effectively disabled.
pub(super) async fn recv_ws_cmd(
    rx: &mut Option<mpsc::Receiver<WsCommand>>,
) -> Option<WsCommand> {
    match rx {
        Some(rx) => rx.recv().await,
        None => std::future::pending().await,
    }
}

/// Handle a single WebSocket command. Runs synchronously on the event
/// loop thread (no concurrent access to the controller).
pub(super) async fn handle_ws_command(
    cmd: WsCommand,
    processor: &mut EventProcessor,
    bridge: &MqttBridge,
    broadcast_tx: &Option<broadcast::Sender<mqtt_controller_wire::ServerMessage>>,
    clock: &dyn Clock,
) {
    match cmd {
        WsCommand::RequestSnapshot { reply } => {
            let snap = snapshot::build_full_snapshot(processor, clock.now());
            let _ = reply.send(snap);
        }
        WsCommand::RequestTopology { reply } => {
            let topo = snapshot::build_topology_info(processor.topology());
            let _ = reply.send(topo);
        }
        WsCommand::RecallScene { room, scene_id } => {
            let actions = processor.web_recall_scene(&room, scene_id, clock.now());
            for action in actions {
                if let Err(e) = bridge.publish_action(&action).await {
                    tracing::error!(error = ?e, "web: failed to publish scene recall");
                }
            }
        }
        WsCommand::SetRoomOff { room } => {
            let actions = processor.web_set_room_off(&room, clock.now());
            for action in actions {
                if let Err(e) = bridge.publish_action(&action).await {
                    tracing::error!(error = ?e, "web: failed to publish room off");
                }
            }
        }
        WsCommand::TogglePlug { device } => {
            let actions = processor.web_toggle_plug(&device, clock.now());
            for action in actions {
                if let Err(e) = bridge.publish_action(&action).await {
                    tracing::error!(error = ?e, "web: failed to publish plug toggle");
                }
            }
        }
    }

    // Broadcast a fresh snapshot after any command so clients see
    // the effect immediately (before the z2m state callback arrives).
    if let Some(tx) = &broadcast_tx {
        broadcast_state_updates(processor, tx, clock.now());
    }
}

/// Broadcast current state of all rooms, plugs, and heating zones to WebSocket clients.
pub(super) fn broadcast_state_updates(
    processor: &EventProcessor,
    tx: &broadcast::Sender<mqtt_controller_wire::ServerMessage>,
    now: Instant,
) {
    let topology = processor.topology();
    for room in topology.rooms() {
        if let Some(snap) = snapshot::build_room_snapshot(processor, &room.name, now) {
            let _ = tx.send(mqtt_controller_wire::ServerMessage::RoomUpdate(snap));
        }
    }
    for plug_name in topology.all_plug_names() {
        if let Some(snap) = snapshot::build_plug_snapshot(processor, plug_name, now) {
            let _ = tx.send(mqtt_controller_wire::ServerMessage::PlugUpdate(snap));
        }
    }
    if let Some(cfg) = topology.heating_config() {
        for zone in &cfg.zones {
            if let Some(snap) = snapshot::build_heating_zone_snapshot(processor, &zone.name, now) {
                let _ = tx.send(mqtt_controller_wire::ServerMessage::HeatingZoneUpdate(snap));
            }
        }
    }
}
