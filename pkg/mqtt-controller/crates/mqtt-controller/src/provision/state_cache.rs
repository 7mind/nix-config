//! WebSocket-based bulk state cache. Connects to z2m's WebSocket API
//! and collects the initial state dump pushed on connect.

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::Value;
use thiserror::Error;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

#[derive(Debug, Error)]
pub enum StateCacheError {
    #[error("WebSocket connection to {url} failed: {source}")]
    Connect {
        url: String,
        source: tokio_tungstenite::tungstenite::Error,
    },
    #[error("WebSocket message error: {0}")]
    Message(#[from] tokio_tungstenite::tungstenite::Error),
    #[error("invalid JSON in WebSocket message: {0}")]
    Json(#[from] serde_json::Error),
    #[error("state dump timed out after {0:?}")]
    Timeout(Duration),
}

#[derive(Deserialize)]
struct WsEnvelope {
    topic: String,
    payload: Value,
}

#[derive(Deserialize)]
struct BridgeDevice {
    friendly_name: String,
    #[serde(rename = "type")]
    device_type: String,
}

/// Connect to z2m's WebSocket API, collect the initial state dump,
/// and return a map of friendly_name -> cached state JSON.
///
/// z2m sends on connect:
///   1. Bridge topics (bridge/state, bridge/info, bridge/devices, etc.)
///   2. Per-device cached state (topic = friendly_name, payload = full state)
///
/// We collect until we've seen state for all non-coordinator devices
/// listed in bridge/devices, then disconnect.
pub async fn fetch_device_states(
    ws_url: &str,
    timeout: Duration,
) -> Result<HashMap<String, Value>, StateCacheError> {
    let (ws_stream, _response) = connect_async(ws_url)
        .await
        .map_err(|e| StateCacheError::Connect {
            url: ws_url.to_string(),
            source: e,
        })?;

    let (_, mut read) = ws_stream.split();
    let mut device_names: Option<HashSet<String>> = None;
    let mut states: HashMap<String, Value> = HashMap::new();
    let deadline = tokio::time::Instant::now() + timeout;

    loop {
        let msg = match tokio::time::timeout_at(deadline, read.next()).await {
            Ok(Some(Ok(msg))) => msg,
            Ok(Some(Err(e))) => return Err(StateCacheError::Message(e)),
            Ok(None) => break,
            Err(_) => {
                if device_names.is_some() {
                    // Timeout after we got the device list — return what we have
                    break;
                }
                return Err(StateCacheError::Timeout(timeout));
            }
        };

        let text = match msg {
            Message::Text(t) => t,
            _ => continue,
        };

        let envelope: WsEnvelope = match serde_json::from_str(&text) {
            Ok(e) => e,
            Err(_) => continue, // skip unparseable messages
        };

        match envelope.topic.as_str() {
            "bridge/devices" => {
                let devices: Vec<BridgeDevice> =
                    serde_json::from_value(envelope.payload)?;
                let names: HashSet<String> = devices
                    .into_iter()
                    .filter(|d| d.device_type != "Coordinator")
                    .map(|d| d.friendly_name)
                    .collect();
                tracing::info!(
                    devices = names.len(),
                    "WebSocket: received device inventory"
                );
                device_names = Some(names);
            }
            t if t.starts_with("bridge/") => continue,
            t if t.ends_with("/availability") => continue,
            name => {
                states.insert(name.to_string(), envelope.payload);
                if let Some(ref names) = device_names {
                    if names.iter().all(|n| states.contains_key(n)) {
                        tracing::info!(
                            devices = states.len(),
                            "WebSocket: received state for all devices"
                        );
                        break;
                    }
                }
            }
        }
    }

    Ok(states)
}
