//! axum HTTP/WebSocket server. Serves the Leptos frontend as static
//! files and provides a WebSocket endpoint for real-time state and
//! control.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use axum::extract::ws::{Message, WebSocket};
use axum::extract::{State, WebSocketUpgrade};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use tokio::sync::{broadcast, mpsc, oneshot};
use tower_http::services::ServeDir;

use hue_wire::{ClientMessage, FullStateSnapshot, ServerMessage, TopologyInfo};

/// Command sent from a WebSocket handler to the daemon event loop.
pub enum WsCommand {
    /// Request a full state snapshot. The event loop builds it from the
    /// controller and sends it back on the oneshot.
    RequestSnapshot {
        reply: oneshot::Sender<FullStateSnapshot>,
    },
    /// Request the static topology info.
    RequestTopology {
        reply: oneshot::Sender<TopologyInfo>,
    },
    /// Recall a specific scene in a room (published to MQTT by the daemon).
    RecallScene { room: String, scene_id: u8 },
    /// Turn a room's group OFF (published to MQTT by the daemon).
    SetRoomOff { room: String },
    /// Toggle a smart plug (published to MQTT by the daemon).
    TogglePlug { device: String },
}

/// Handle passed from main into daemon::run so the event loop can
/// receive commands from WebSocket handlers and broadcast events.
pub struct WebHandle {
    pub ws_cmd_rx: mpsc::Receiver<WsCommand>,
    pub broadcast_tx: broadcast::Sender<ServerMessage>,
}

/// Shared state available to all axum handlers.
struct AppState {
    ws_cmd_tx: mpsc::Sender<WsCommand>,
    broadcast_tx: broadcast::Sender<ServerMessage>,
}

/// Start the web server. Returns a `JoinHandle` for the server task.
pub fn start_web_server(
    addr: SocketAddr,
    ws_cmd_tx: mpsc::Sender<WsCommand>,
    broadcast_tx: broadcast::Sender<ServerMessage>,
    assets_dir: PathBuf,
) -> tokio::task::JoinHandle<anyhow::Result<()>> {
    let state = Arc::new(AppState {
        ws_cmd_tx,
        broadcast_tx,
    });

    let app = Router::new()
        .route("/ws", get(ws_handler))
        .fallback_service(ServeDir::new(assets_dir))
        .with_state(state);

    tokio::spawn(async move {
        let listener = tokio::net::TcpListener::bind(addr).await?;
        tracing::info!(%addr, "web server listening");
        axum::serve(listener, app).await?;
        Ok(())
    })
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_ws_connection(socket, state))
}

async fn handle_ws_connection(socket: WebSocket, state: Arc<AppState>) {
    let (mut ws_tx, mut ws_rx) = socket.split();
    let mut broadcast_rx = state.broadcast_tx.subscribe();

    // Send initial snapshot on connect.
    let snapshot = request_snapshot(&state.ws_cmd_tx).await;
    if let Some(snap) = snapshot {
        let msg = ServerMessage::StateSnapshot(snap);
        if send_json(&mut ws_tx, &msg).await.is_err() {
            return;
        }
    }

    // Spawn writer task: forward broadcast messages to the WS client.
    let write_handle = tokio::spawn(async move {
        loop {
            match broadcast_rx.recv().await {
                Ok(msg) => {
                    if send_json(&mut ws_tx, &msg).await.is_err() {
                        break;
                    }
                }
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    tracing::warn!(skipped = n, "ws client lagged, skipping messages");
                }
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    });

    // Reader loop: parse client messages and dispatch commands.
    while let Some(Ok(msg)) = ws_rx.next().await {
        match msg {
            Message::Text(text) => {
                if let Ok(client_msg) = serde_json::from_str::<ClientMessage>(&text) {
                    handle_client_message(&state, client_msg).await;
                }
            }
            Message::Close(_) => break,
            _ => {}
        }
    }

    write_handle.abort();
}

async fn handle_client_message(state: &AppState, msg: ClientMessage) {
    match msg {
        ClientMessage::GetState => {
            if let Some(snap) = request_snapshot(&state.ws_cmd_tx).await {
                let _ = state
                    .broadcast_tx
                    .send(ServerMessage::StateSnapshot(snap));
            }
        }
        ClientMessage::GetTopology => {
            let (tx, rx) = oneshot::channel();
            let _ = state
                .ws_cmd_tx
                .send(WsCommand::RequestTopology { reply: tx })
                .await;
            if let Ok(topo) = rx.await {
                let _ = state.broadcast_tx.send(ServerMessage::Topology(topo));
            }
        }
        ClientMessage::RecallScene { room, scene_id } => {
            let _ = state
                .ws_cmd_tx
                .send(WsCommand::RecallScene { room, scene_id })
                .await;
        }
        ClientMessage::SetRoomOff { room } => {
            let _ = state
                .ws_cmd_tx
                .send(WsCommand::SetRoomOff { room })
                .await;
        }
        ClientMessage::TogglePlug { device } => {
            let _ = state
                .ws_cmd_tx
                .send(WsCommand::TogglePlug { device })
                .await;
        }
    }
}

async fn request_snapshot(
    ws_cmd_tx: &mpsc::Sender<WsCommand>,
) -> Option<FullStateSnapshot> {
    let (tx, rx) = oneshot::channel();
    ws_cmd_tx
        .send(WsCommand::RequestSnapshot { reply: tx })
        .await
        .ok()?;
    rx.await.ok()
}

use futures_util::{SinkExt, StreamExt};
use futures_util::stream::SplitSink;

async fn send_json(
    tx: &mut SplitSink<WebSocket, Message>,
    msg: &ServerMessage,
) -> Result<(), ()> {
    let json = serde_json::to_string(msg).map_err(|_| ())?;
    tx.send(Message::text(json)).await.map_err(|_: axum::Error| ())
}
