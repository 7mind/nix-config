//! zigbee2mqtt WebSocket API client.
//!
//! One entry point: [`fetch_device_states`]. Opens the `/api` endpoint,
//! consumes the initial dump z2m pushes on connect (`bridge/state`,
//! `bridge/info`, `bridge/devices`, then one message per device with
//! its cached state), and returns a `friendly_name → state JSON` map.
//!
//! Shared between:
//!   - the **provisioner**, which uses it for per-device-option dedup, and
//!   - the **daemon startup seed**, which uses it to prime every
//!     entity's actual state in a single MQTT-less round-trip (replacing
//!     the former retained-drain + `/get` cascade).
//!
//! Works for sleeping/offline devices (z2m has their cached state).
//! Requires the z2m frontend to be enabled — already required by the
//! provisioner, so not a new operational concern.

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

#[derive(Deserialize)]
struct BridgeGroup {
    friendly_name: String,
}

/// Connect, wait for the initial dump, and return `friendly_name →
/// cached state JSON`. Retries on transient failures or empty responses
/// (z2m up but inventory not yet published — common race on boot).
/// Fails only after `attempts` tries with `retry_delay` between them.
pub async fn fetch_device_states_with_retry(
    ws_url: &str,
    timeout: Duration,
    attempts: u32,
    retry_delay: Duration,
) -> Result<HashMap<String, Value>, StateCacheError> {
    let mut last_err: Option<StateCacheError> = None;
    for attempt in 1..=attempts {
        match fetch_device_states(ws_url, timeout).await {
            Ok(cache) if cache.is_empty() => {
                tracing::warn!(
                    attempt,
                    max = attempts,
                    "z2m WebSocket state cache returned empty; retrying"
                );
            }
            Ok(cache) => {
                tracing::info!(
                    devices = cache.len(),
                    attempt,
                    "z2m WebSocket state cache loaded"
                );
                return Ok(cache);
            }
            Err(e) => {
                tracing::warn!(
                    attempt,
                    max = attempts,
                    error = %e,
                    "z2m WebSocket state cache fetch failed"
                );
                last_err = Some(e);
            }
        }
        if attempt < attempts {
            tokio::time::sleep(retry_delay).await;
        }
    }
    Err(last_err.unwrap_or(StateCacheError::Timeout(timeout)))
}

/// Connect to z2m's WebSocket API, collect the initial state dump,
/// and return a map of `friendly_name → cached state JSON`. The map
/// contains entries for both individual **devices** and **z2m groups**
/// (those publish on the same `zigbee2mqtt/<friendly_name>` topic
/// pattern and are indistinguishable from the envelope alone).
///
/// z2m sends on connect:
///   1. Bridge topics (`bridge/state`, `bridge/info`, `bridge/devices`,
///      `bridge/groups`, `bridge/logging`, etc.)
///   2. Per-entity cached state — one message per device and per group
///      that has ever had a retained publish.
///
/// We collect until every non-coordinator device from `bridge/devices`
/// AND every group from `bridge/groups` has a state entry (or the
/// timeout elapses). `bridge/groups` used to be silently dropped, which
/// caused the daemon seed to miss every zone's aggregate state.
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
    let mut group_names: Option<HashSet<String>> = None;
    let mut states: HashMap<String, Value> = HashMap::new();
    let deadline = tokio::time::Instant::now() + timeout;

    loop {
        let msg = match tokio::time::timeout_at(deadline, read.next()).await {
            Ok(Some(Ok(msg))) => msg,
            Ok(Some(Err(e))) => return Err(StateCacheError::Message(e)),
            Ok(None) => break,
            Err(_) => {
                // Timeout after we got at least the device list: return
                // what we have. Groups may be missing retained state if
                // they never published; not fatal.
                if device_names.is_some() {
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
                    "z2m WebSocket: received device inventory"
                );
                device_names = Some(names);
            }
            "bridge/groups" => {
                let groups: Vec<BridgeGroup> =
                    serde_json::from_value(envelope.payload)?;
                let names: HashSet<String> =
                    groups.into_iter().map(|g| g.friendly_name).collect();
                tracing::info!(
                    groups = names.len(),
                    "z2m WebSocket: received group inventory"
                );
                group_names = Some(names);
            }
            t if t.starts_with("bridge/") => continue,
            t if t.ends_with("/availability") => continue,
            name => {
                states.insert(name.to_string(), envelope.payload);
                if seen_all(&device_names, &group_names, &states) {
                    tracing::info!(
                        entries = states.len(),
                        "z2m WebSocket: received state for all devices + groups"
                    );
                    break;
                }
            }
        }
    }

    Ok(states)
}

/// True when both the device and group inventory messages have been
/// seen AND every listed name has a corresponding state entry.
fn seen_all(
    devices: &Option<HashSet<String>>,
    groups: &Option<HashSet<String>>,
    states: &HashMap<String, Value>,
) -> bool {
    let Some(d) = devices else { return false };
    let Some(g) = groups else { return false };
    d.iter().all(|n| states.contains_key(n)) && g.iter().all(|n| states.contains_key(n))
}
