//! axum HTTP/WebSocket server. Serves the Leptos frontend as static
//! files and provides a WebSocket endpoint for real-time state and
//! control.
//!
//! Connection-liveness model
//! -------------------------
//! The transport's `close` event is unreliable (Firefox WS bug, mobile
//! NAT idle drops, IP changes), so liveness is established at the
//! application layer:
//!
//! 1. **Client-driven heartbeat** — the browser sends `ClientMessage::
//!    Ping { nonce, client_ts_ms }`; the server replies with
//!    `ServerMessage::Pong { ... }` carrying the same nonce. RTT is
//!    computed entirely from the echoed `client_ts_ms`, so no clock
//!    sync between peers is assumed.
//! 2. **Server-driven heartbeat** — every [`PING_INTERVAL`], the server
//!    sends an RFC 6455 `Message::Ping(nonce)` frame. The browser
//!    auto-replies with a `Message::Pong`. If two consecutive pings go
//!    unanswered (the [`MAX_MISSED_PINGS`] budget), the writer task
//!    closes the connection so the client's reconnect logic kicks in.
//!    Nonces are correlated with a one-tick lookback (current OR
//!    previous nonce accepted) to (a) reject unsolicited pongs allowed
//!    by RFC 6455 §5.5.3, and (b) tolerate a tick rotation racing a
//!    pong already in flight.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use axum::extract::ws::{CloseFrame, Message, WebSocket};
use axum::extract::{Request, State, WebSocketUpgrade};
use axum::middleware;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use tokio::sync::{broadcast, mpsc, oneshot, Mutex};
use tokio::time::{interval, Duration, MissedTickBehavior};
use tower_http::services::ServeDir;
use turso::Database;

use mqtt_controller_wire::{ClientMessage, FullStateSnapshot, ServerMessage, TopologyInfo};

use crate::audit::AuditWriterHandle;

/// Server-driven heartbeat cadence. Cellular NATs drop idle 4-tuples
/// after ~30s, so this must be well under that.
const PING_INTERVAL: Duration = Duration::from_secs(15);

/// Number of consecutive missed pings tolerated before the server closes
/// the connection. One missed ping is normal under brief stalls (GC, a
/// long event handler); two in a row means the client is genuinely gone.
const MAX_MISSED_PINGS: u32 = 2;

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

/// Heartbeat liveness tracking. The writer task generates nonces; the
/// reader task clears `pending` on matching pongs. One-tick lookback
/// (current OR previous) tolerates a nonce rotation racing an in-flight
/// pong.
#[derive(Default)]
struct HeartbeatState {
    current_nonce: Option<Vec<u8>>,
    previous_nonce: Option<Vec<u8>>,
    /// Number of consecutive pings sent without a matching pong.
    missed: u32,
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

    let heartbeat = Arc::new(Mutex::new(HeartbeatState::default()));

    // Writer task: broadcast + direct ServerMessages, plus the server-
    // side liveness heartbeat. Returns once the connection should close
    // (peer gone, channel error, or heartbeat budget exhausted).
    let writer_heartbeat = Arc::clone(&heartbeat);
    let write_handle = tokio::spawn(async move {
        let mut hb_interval = interval(PING_INTERVAL);
        // First tick fires immediately; consume it so we don't ping on
        // connect (the snapshot we just sent is enough proof of life).
        hb_interval.tick().await;
        hb_interval.set_missed_tick_behavior(MissedTickBehavior::Skip);

        loop {
            tokio::select! {
                biased;
                result = broadcast_rx.recv() => {
                    match result {
                        Ok(msg) => {
                            if send_json(&mut ws_tx, &msg).await.is_err() {
                                break;
                            }
                        }
                        Err(broadcast::error::RecvError::Lagged(n)) => {
                            tracing::warn!(skipped = n, "ws client lagged, skipping messages");
                            continue;
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
                result = direct_rx.recv() => {
                    match result {
                        Some(msg) => {
                            if send_json(&mut ws_tx, &msg).await.is_err() {
                                break;
                            }
                        }
                        None => break,
                    }
                }
                _ = hb_interval.tick() => {
                    // Examine + advance the heartbeat state atomically:
                    // if the previous nonce is still pending, count a
                    // miss; otherwise rotate in a fresh nonce.
                    let nonce = {
                        let mut hb = writer_heartbeat.lock().await;
                        if hb.current_nonce.is_some() {
                            hb.missed = hb.missed.saturating_add(1);
                            if hb.missed >= MAX_MISSED_PINGS {
                                tracing::warn!(
                                    missed = hb.missed,
                                    "ws client did not respond to heartbeat, closing"
                                );
                                drop(hb);
                                let _ = ws_tx
                                    .send(Message::Close(Some(CloseFrame {
                                        code: 1011,
                                        reason: "heartbeat timeout".into(),
                                    })))
                                    .await;
                                break;
                            }
                        }
                        let new_nonce = make_nonce();
                        hb.previous_nonce = hb.current_nonce.take();
                        hb.current_nonce = Some(new_nonce.clone());
                        new_nonce
                    };
                    if ws_tx
                        .send(Message::Ping(nonce.into()))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
            }
        }
    });

    // Reader loop: parse client messages, dispatch commands, clear
    // heartbeat state on matching pongs.
    while let Some(Ok(msg)) = ws_rx.next().await {
        match msg {
            Message::Text(text) => {
                if let Ok(client_msg) = serde_json::from_str::<ClientMessage>(&text) {
                    handle_client_message(&state, client_msg, &direct_tx).await;
                }
            }
            Message::Pong(bytes) => {
                let echoed: &[u8] = &bytes;
                let mut hb = heartbeat.lock().await;
                let matches_current =
                    hb.current_nonce.as_deref() == Some(echoed);
                let matches_previous =
                    hb.previous_nonce.as_deref() == Some(echoed);
                if matches_current || matches_previous {
                    // Pong correlated → both pending slots are answered.
                    // Clearing both is the conservative thing: if the
                    // pong matched `previous`, the in-flight `current`
                    // counts as answered too (the client is alive).
                    hb.current_nonce = None;
                    hb.previous_nonce = None;
                    hb.missed = 0;
                }
                // Unsolicited pongs (no matching nonce) are silently
                // dropped per RFC 6455 §5.5.3 — they MUST NOT be used
                // as proof of liveness.
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
        ClientMessage::Ping {
            nonce,
            client_ts_ms,
        } => {
            // App-layer heartbeat from the client; reply immediately so
            // the client can compute its own RTT and prove this exact
            // channel is alive (not just *some* server traffic).
            let server_ts_ms = chrono::Utc::now().timestamp_millis();
            let _ = direct_tx
                .send(ServerMessage::Pong {
                    nonce,
                    client_ts_ms,
                    server_ts_ms,
                })
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

/// 16-byte heartbeat nonce. UUID v4's randomness is more than enough;
/// the wire encoding is the raw 16 bytes (RFC 6455 ping payloads can be
/// any bytes up to 125, so we don't need string encoding).
fn make_nonce() -> Vec<u8> {
    uuid::Uuid::new_v4().as_bytes().to_vec()
}

use futures_util::stream::SplitSink;
use futures_util::{SinkExt, StreamExt};

async fn send_json(
    tx: &mut SplitSink<WebSocket, Message>,
    msg: &ServerMessage,
) -> Result<(), ()> {
    let json = serde_json::to_string(msg).map_err(|_| ())?;
    tx.send(Message::text(json)).await.map_err(|_: axum::Error| ())
}
