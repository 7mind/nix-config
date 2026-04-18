//! `zwave-js-server` WebSocket client for the daemon startup seed.
//!
//! ZJS-UI embeds `zwave-js-server` (upstream protocol server) on a
//! separate port (3000 by default). The protocol is a plain WebSocket
//! carrying JSON-RPC-like messages — no socket.io framing, no auth by
//! default. `tokio-tungstenite` (already a dependency for the z2m seed)
//! handles it natively.
//!
//! Four round-trips to get a full state snapshot:
//!
//! 1. On connect, server sends `{"type":"version",...,"maxSchemaVersion":N}`.
//! 2. Client sends `set_api_schema` with a schema version (we use the
//!    server-advertised max — forward-compatible with older zwave-js
//!    servers that wouldn't understand newer fields anyway).
//! 3. Server replies with `{"type":"result","success":true}`.
//! 4. Client sends `start_listening`. Server replies with the full
//!    driver+controller+nodes state in `result.state` and then begins
//!    streaming events (which we ignore — we close right after).
//!
//! The same result we used to get via the MQTT `getNodes` API, but
//! live (in-memory state, not the persisted nodes.json file), and
//! without spinning up a parallel MQTT client.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use thiserror::Error;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

use crate::mqtt::zwave_api::ZwaveNode;
use crate::mqtt::codec::zwave_meter;

#[derive(Debug, Error)]
pub enum ZwaveServerError {
    #[error("WebSocket connection to {url} failed: {source}")]
    Connect {
        url: String,
        source: tokio_tungstenite::tungstenite::Error,
    },
    #[error("WebSocket message error: {0}")]
    Message(#[from] tokio_tungstenite::tungstenite::Error),
    #[error("invalid JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("unexpected handshake: {0}")]
    Handshake(String),
    #[error("server returned error: {0}")]
    ServerError(String),
    #[error("timed out after {0:?}")]
    Timeout(Duration),
}

/// Fetch the current state of every Z-Wave node from `zwave-js-server`.
/// One WebSocket round-trip over plain TCP, no MQTT.
///
/// Returns every node the driver knows about — online or not — so the
/// daemon can seed state even for sleeping battery devices.
pub async fn fetch_nodes(
    ws_url: &str,
    timeout: Duration,
) -> Result<Vec<ZwaveNode>, ZwaveServerError> {
    let deadline = tokio::time::Instant::now() + timeout;

    let (ws_stream, _response) = tokio::time::timeout_at(deadline, connect_async(ws_url))
        .await
        .map_err(|_| ZwaveServerError::Timeout(timeout))?
        .map_err(|e| ZwaveServerError::Connect {
            url: ws_url.to_string(),
            source: e,
        })?;

    let (mut write, mut read) = ws_stream.split();

    // Step 1: read the version greeting and extract the schema range.
    let version = read_next_json(&mut read, deadline).await?;
    if version.get("type").and_then(|v| v.as_str()) != Some("version") {
        return Err(ZwaveServerError::Handshake(format!(
            "expected version message, got {version}"
        )));
    }
    let schema_version = version
        .get("maxSchemaVersion")
        .and_then(|v| v.as_u64())
        .ok_or_else(|| {
            ZwaveServerError::Handshake("version message missing maxSchemaVersion".into())
        })?;

    // Step 2: negotiate schema.
    write
        .send(Message::Text(
            json!({
                "messageId": "1",
                "command": "set_api_schema",
                "schemaVersion": schema_version,
            })
            .to_string()
            .into(),
        ))
        .await?;
    let resp = read_next_json(&mut read, deadline).await?;
    expect_success(&resp, "1")?;

    // Step 3: start_listening → server responds with full initial state.
    write
        .send(Message::Text(
            json!({"messageId": "2", "command": "start_listening"})
                .to_string()
                .into(),
        ))
        .await?;
    let resp = read_next_json(&mut read, deadline).await?;
    expect_success(&resp, "2")?;

    // Close the socket; we don't need the event stream.
    let _ = write.send(Message::Close(None)).await;

    let nodes = resp
        .get("result")
        .and_then(|r| r.get("state"))
        .and_then(|s| s.get("nodes"))
        .and_then(|n| n.as_array())
        .ok_or_else(|| {
            ZwaveServerError::Handshake("start_listening result missing state.nodes".into())
        })?;

    Ok(nodes.iter().filter_map(parse_node).collect())
}

/// Read one text WebSocket message, parse JSON, return. Returns a timeout
/// error if the deadline elapses. Non-text frames (pings/closes) are
/// silently passed over — `connect_async` handles pings for us.
async fn read_next_json(
    read: &mut (impl StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>>
          + Unpin),
    deadline: tokio::time::Instant,
) -> Result<Value, ZwaveServerError> {
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(ZwaveServerError::Timeout(remaining));
        }
        let msg = match tokio::time::timeout(remaining, read.next()).await {
            Ok(Some(Ok(msg))) => msg,
            Ok(Some(Err(e))) => return Err(ZwaveServerError::Message(e)),
            Ok(None) => {
                return Err(ZwaveServerError::Handshake(
                    "WebSocket closed before response".into(),
                ))
            }
            Err(_) => return Err(ZwaveServerError::Timeout(remaining)),
        };
        match msg {
            Message::Text(t) => return Ok(serde_json::from_str(&t)?),
            Message::Close(_) => {
                return Err(ZwaveServerError::Handshake(
                    "server closed the socket".into(),
                ));
            }
            // Ignore Ping/Pong/Binary.
            _ => continue,
        }
    }
}

/// Verify the envelope `{"type":"result","messageId":"<id>","success":true}`.
/// Failure responses carry `errorCode`/`message` fields.
fn expect_success(resp: &Value, message_id: &str) -> Result<(), ZwaveServerError> {
    if resp.get("type").and_then(|v| v.as_str()) != Some("result") {
        return Err(ZwaveServerError::Handshake(format!(
            "expected result envelope, got {resp}"
        )));
    }
    if resp.get("messageId").and_then(|v| v.as_str()) != Some(message_id) {
        return Err(ZwaveServerError::Handshake(format!(
            "wrong messageId in result: {resp}"
        )));
    }
    if resp.get("success").and_then(|v| v.as_bool()) != Some(true) {
        let err = resp
            .get("errorCode")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown");
        let msg = resp.get("message").and_then(|v| v.as_str()).unwrap_or("");
        return Err(ZwaveServerError::ServerError(format!("{err}: {msg}")));
    }
    Ok(())
}

/// Parse one node entry from `start_listening`'s state.nodes array into
/// our `ZwaveNode` shape. Returns `None` for entries without an `id`.
fn parse_node(entry: &Value) -> Option<ZwaveNode> {
    let node_id = entry.get("nodeId").and_then(|v| v.as_u64())? as u16;

    let raw_name = entry.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let current_name = if raw_name.is_empty() {
        format!("nodeID_{node_id}")
    } else {
        raw_name.to_string()
    };
    let current_location = entry
        .get("location")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    // `values` is an array in the zwave-js-server protocol. Each entry
    // has `commandClass` (numeric), `endpoint`, `property`, optional
    // `propertyKey`, and `currentValue`. We scan for the two we care
    // about — matching the MQTT-side extractors.
    let values = entry.get("values").and_then(|v| v.as_array());
    let (switch_on, power_w) = match values {
        Some(arr) => (extract_switch_on(arr), extract_power_w(arr)),
        None => (None, None),
    };

    Some(ZwaveNode {
        node_id,
        current_name,
        current_location,
        switch_on,
        power_w,
    })
}

/// switch_binary (CC 37 = 0x25), endpoint 0, property `currentValue`.
fn extract_switch_on(values: &[Value]) -> Option<bool> {
    values.iter().find_map(|v| {
        let cc = v.get("commandClass")?.as_u64()?;
        let ep = v.get("endpoint")?.as_u64()?;
        let prop = v.get("property")?.as_str()?;
        if cc == 37 && ep == 0 && prop == "currentValue" {
            v.get("currentValue").and_then(|x| x.as_bool())
        } else {
            None
        }
    })
}

/// Electric meter (CC 50 = 0x32), endpoint 0, property `value`, propertyKey
/// matches our `POWER_W` constant. Clamps negative readings to zero
/// (NAS-WR01ZE reports bogus negatives occasionally).
fn extract_power_w(values: &[Value]) -> Option<f64> {
    values.iter().find_map(|v| {
        let cc = v.get("commandClass")?.as_u64()?;
        let ep = v.get("endpoint")?.as_u64()?;
        let prop = v.get("property")?.as_str()?;
        let pk = v.get("propertyKey")?.as_u64()?;
        if cc == 50 && ep == 0 && prop == "value" && pk == zwave_meter::POWER_W as u64 {
            let watts = v.get("currentValue")?.as_f64()?;
            Some(watts.max(0.0))
        } else {
            None
        }
    })
}

#[cfg(test)]
#[path = "zwave_server_tests.rs"]
mod tests;
