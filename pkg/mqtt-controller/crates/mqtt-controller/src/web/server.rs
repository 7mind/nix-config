//! axum HTTP/WebSocket server. Serves the Leptos frontend as static
//! files and provides a WebSocket endpoint for real-time state and
//! control.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use axum::extract::ws::{Message, WebSocket};
use axum::extract::{Request, State, WebSocketUpgrade};
use axum::middleware;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use tokio::sync::{broadcast, mpsc, oneshot};
use tower_http::services::ServeDir;
use turso::Database;

use mqtt_controller_wire::{ClientMessage, FullStateSnapshot, ServerMessage, TopologyInfo};

use crate::audit::AuditWriterHandle;

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
    /// Optional audit-log writer. When present, the event loop persists
    /// each broadcast `DecisionLogEntry` to disk so the per-entity
    /// popup history survives daemon restarts.
    pub audit_writer: Option<AuditWriterHandle>,
}

/// Shared state available to all axum handlers.
struct AppState {
    ws_cmd_tx: mpsc::Sender<WsCommand>,
    broadcast_tx: broadcast::Sender<ServerMessage>,
    /// Optional audit-log read handle. When present, the WebSocket
    /// handler answers `ClientMessage::GetEntityLog` queries directly
    /// against the database without round-tripping through the event
    /// loop (queries are read-only and do not need to be serialized
    /// against state writes).
    audit_db: Option<Database>,
}

/// Bind the TCP listener synchronously and spawn the web server.
/// Returns the listener address (useful when port 0 is used in tests)
/// and the server task handle.
///
/// Binding happens before the spawn so that port-in-use errors surface
/// immediately to the caller rather than being silently swallowed.
pub async fn bind_and_start_web_server(
    addr: SocketAddr,
    ws_cmd_tx: mpsc::Sender<WsCommand>,
    broadcast_tx: broadcast::Sender<ServerMessage>,
    assets_dir: PathBuf,
    audit_db: Option<Database>,
) -> anyhow::Result<(SocketAddr, tokio::task::JoinHandle<anyhow::Result<()>>)> {
    let state = Arc::new(AppState {
        ws_cmd_tx,
        broadcast_tx,
        audit_db,
    });

    let app = Router::new()
        .route("/ws", get(ws_handler))
        .fallback_service(ServeDir::new(assets_dir))
        .layer(middleware::from_fn(cache_control))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    let bound_addr = listener.local_addr()?;
    tracing::info!(%bound_addr, "web server listening");

    let handle = tokio::spawn(async move {
        axum::serve(listener, app).await?;
        Ok(())
    });

    Ok((bound_addr, handle))
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

    // Channel for direct replies to this connection (not broadcast).
    let (direct_tx, mut direct_rx) = mpsc::channel::<ServerMessage>(16);

    // Send initial snapshot on connect.
    let snapshot = request_snapshot(&state.ws_cmd_tx).await;
    if let Some(snap) = snapshot {
        let msg = ServerMessage::StateSnapshot(snap);
        if send_json(&mut ws_tx, &msg).await.is_err() {
            return;
        }
    }

    // Spawn writer task: merges broadcast messages and direct replies
    // into the WebSocket send stream.
    let write_handle = tokio::spawn(async move {
        loop {
            let msg = tokio::select! {
                result = broadcast_rx.recv() => {
                    match result {
                        Ok(msg) => msg,
                        Err(broadcast::error::RecvError::Lagged(n)) => {
                            tracing::warn!(skipped = n, "ws client lagged, skipping messages");
                            continue;
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
                result = direct_rx.recv() => {
                    match result {
                        Some(msg) => msg,
                        None => break,
                    }
                }
            };
            if send_json(&mut ws_tx, &msg).await.is_err() {
                break;
            }
        }
    });

    // Reader loop: parse client messages and dispatch commands.
    while let Some(Ok(msg)) = ws_rx.next().await {
        match msg {
            Message::Text(text) => {
                if let Ok(client_msg) = serde_json::from_str::<ClientMessage>(&text) {
                    handle_client_message(&state, client_msg, &direct_tx).await;
                }
            }
            Message::Close(_) => break,
            _ => {}
        }
    }

    write_handle.abort();
}

async fn handle_client_message(
    state: &AppState,
    msg: ClientMessage,
    direct_tx: &mpsc::Sender<ServerMessage>,
) {
    match msg {
        ClientMessage::GetState => {
            if let Some(snap) = request_snapshot(&state.ws_cmd_tx).await {
                let _ = direct_tx.send(ServerMessage::StateSnapshot(snap)).await;
            }
        }
        ClientMessage::GetTopology => {
            let (tx, rx) = oneshot::channel();
            let _ = state
                .ws_cmd_tx
                .send(WsCommand::RequestTopology { reply: tx })
                .await;
            if let Ok(topo) = rx.await {
                let _ = direct_tx.send(ServerMessage::Topology(topo)).await;
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
        ClientMessage::GetEntityLog {
            entity,
            before_ts_ms,
            limit,
        } => {
            let Some(db) = state.audit_db.as_ref() else {
                // Audit log disabled: return an empty response so the
                // popup gracefully shows "no history" instead of
                // hanging on a request that nobody will answer.
                let _ = direct_tx
                    .send(ServerMessage::EntityLog {
                        entity,
                        entries: Vec::new(),
                        has_more: false,
                    })
                    .await;
                return;
            };
            let requested_limit = limit
                .unwrap_or(crate::audit::DEFAULT_LIMIT)
                .clamp(1, crate::audit::MAX_LIMIT);
            match crate::audit::fetch(db, &entity, before_ts_ms, Some(requested_limit)).await {
                Ok(entries) => {
                    let has_more = entries.len() as u32 == requested_limit;
                    let _ = direct_tx
                        .send(ServerMessage::EntityLog {
                            entity,
                            entries,
                            has_more,
                        })
                        .await;
                }
                Err(e) => {
                    tracing::warn!(error = %e, %entity, "audit log query failed");
                    let _ = direct_tx
                        .send(ServerMessage::EntityLog {
                            entity,
                            entries: Vec::new(),
                            has_more: false,
                        })
                        .await;
                }
            }
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

/// Trunk uses content-hashed filenames for all assets except index.html.
/// Mark index.html as non-cacheable so browsers always fetch the latest
/// asset references after a deploy.
async fn cache_control(request: Request, next: middleware::Next) -> Response {
    let path = request.uri().path().to_owned();
    let mut response = next.run(request).await;
    if path == "/" || path == "/index.html" {
        response.headers_mut().insert(
            axum::http::header::CACHE_CONTROL,
            axum::http::HeaderValue::from_static("no-cache"),
        );
    }
    response
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
