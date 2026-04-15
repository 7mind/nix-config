# Proposal: Fetch device state via z2m WebSocket API

## Background

The provisioner's Phase 4 (`reconcile_devices`) reads each device's current state to dedup option writes. It currently subscribes to `zigbee2mqtt/<device>` and waits for a retained MQTT message. z2m publishes device state with `retain: false` by default, so the fetch always times out and all options are written unconditionally.

z2m has no bridge request endpoint to query cached state. However, when a WebSocket client connects to `ws://<host>:<port>/api`, z2m immediately pushes the full in-memory cached state for every device as individual messages:

```json
{"topic": "<friendly_name>", "payload": {"occupancy_timeout": 60, "motion_sensitivity": "medium", ...}}
```

## Changes

### 1. New config: `z2m_ws_url`

Add a `z2m_ws_url` field to `ProvisionOptions` (or pass separately to `reconcile`). Sourced from the NixOS module which already knows the frontend host/port.

```rust
// provision/mod.rs
pub struct ProvisionOptions {
    // ... existing fields ...
    /// z2m frontend WebSocket URL for fetching cached device state.
    /// e.g. "ws://localhost:8080/api"
    pub z2m_ws_url: String,
}
```

### 2. New module: `provision/state_cache.rs`

A single async function that connects to the WebSocket, collects the initial state dump, and returns a map:

```rust
// provision/state_cache.rs

use std::collections::HashMap;
use serde_json::Value;
use tokio_tungstenite::connect_async;
use futures_util::StreamExt;

/// Connect to z2m's WebSocket API, collect the initial state dump,
/// and return a map of friendly_name -> cached state JSON.
///
/// z2m sends two phases on connect:
///   1. Bridge retained messages (bridge/state, bridge/info, bridge/devices, etc.)
///   2. Per-device cached state (topic = friendly_name, payload = full state)
///
/// We collect until we've seen state for all devices listed in bridge/devices,
/// then disconnect.
pub async fn fetch_device_states(
    ws_url: &str,
    timeout: Duration,
) -> Result<HashMap<String, Value>, StateError> {
    let (mut ws, _) = connect_async(ws_url).await?;

    let mut device_names: Option<HashSet<String>> = None;
    let mut states: HashMap<String, Value> = HashMap::new();
    let deadline = tokio::time::Instant::now() + timeout;

    loop {
        let msg = match tokio::time::timeout_at(deadline, ws.next()).await {
            Ok(Some(Ok(msg))) => msg,
            Ok(Some(Err(e))) => return Err(e.into()),
            Ok(None) => break,          // stream closed
            Err(_) => break,            // timeout
        };

        let text = match msg {
            Message::Text(t) => t,
            _ => continue,
        };

        let envelope: WsEnvelope = serde_json::from_str(&text)?;

        match envelope.topic.as_str() {
            // Phase 1: capture device inventory to know when we're done
            "bridge/devices" => {
                let devices: Vec<BridgeDevice> =
                    serde_json::from_value(envelope.payload)?;
                device_names = Some(
                    devices.iter()
                        .filter(|d| d.r#type != "Coordinator")
                        .map(|d| d.friendly_name.clone())
                        .collect()
                );
            }
            // Skip other bridge/* topics
            t if t.starts_with("bridge/") => continue,
            // Skip availability topics
            t if t.ends_with("/availability") => continue,
            // Phase 2: device state
            name => {
                states.insert(name.to_string(), envelope.payload);
                // Done once we've seen all devices
                if let Some(ref names) = device_names {
                    if names.iter().all(|n| states.contains_key(n)) {
                        break;
                    }
                }
            }
        }
    }

    let _ = ws.close(None).await;
    Ok(states)
}

#[derive(Deserialize)]
struct WsEnvelope {
    topic: String,
    payload: Value,
}

#[derive(Deserialize)]
struct BridgeDevice {
    friendly_name: String,
    r#type: String,
}
```

**Dependencies:** `tokio-tungstenite` (already in the lock file via axum) and `futures-util` (already a direct dependency).

### 3. Modify `reconcile()` in `provision/mod.rs`

Fetch the state cache once before Phase 4, pass it to `reconcile_devices`:

```rust
// Between Phase 3 and Phase 4:

// Fetch cached device state from z2m's WebSocket API.
let device_state_cache = state_cache::fetch_device_states(
    &options.z2m_ws_url,
    options.timeout,
).await.context("fetching device state cache from z2m frontend")?;

// Phase 4: per-device options (now uses cached state).
let device_summary = devices::reconcile_devices(
    &client, config, &options, &device_state_cache,
).await?;
```

### 4. Simplify `devices.rs`

Replace the per-device `fetch_device_state()` call with a map lookup:

```rust
pub async fn reconcile_devices(
    client: &Z2mClient,
    config: &Config,
    options: &ProvisionOptions,
    state_cache: &HashMap<String, Value>,   // <- new parameter
) -> Result<ReconcileSummary, ProvisionError> {
    // ...
    for (friendly_name, entry) in &config.devices {
        // ...
        let existing_state = state_cache.get(friendly_name.as_str());
        if existing_state.is_none() {
            tracing::info!(
                device = %friendly_name,
                "[warn] no cached state from z2m frontend; will write all options unconditionally"
            );
        }
        let existing_obj = existing_state.and_then(|v| v.as_object());
        // ... rest unchanged ...
    }
}
```

### 5. Remove `fetch_device_state()` from `client.rs`

The method and its doc comment (lines 520-564) become dead code. Remove it.

### 6. Wire up in NixOS module

Pass the frontend URL from the existing z2m config:

```nix
# In the mqtt-controller service configuration
z2m_ws_url = "ws://localhost:${toString cfg.port}/api";
```

## What doesn't change

- The MQTT `Z2mClient` still handles Phases 1-3 (renames, descriptions, groups, scenes) and the `/set` writes in Phase 4
- The request/response correlation, topic cache, and retry logic are untouched
- The `set_device_options()` publish path stays the same

## Testing

- **Unit test:** Mock WebSocket server that sends the z2m initial dump sequence; verify `fetch_device_states` returns the correct map
- **E2E test:** Extend the existing `e2e_provision` tests -- spin up a lightweight WS server alongside the embedded MQTT broker, verify that reconcile_devices skips options that match cached state
- **Manual:** Run `mqtt-controller provision --dry-run` and verify the logs show `[skip]` instead of `set` for already-correct options

## Risk

- **z2m frontend disabled:** If the frontend is off, the WebSocket connection fails. This should be a hard error (fail-fast) since the provisioner can't dedup without state. The z2m frontend is already required for the dashboard.
- **Auth token:** If `frontend.auth_token` is set in z2m config, we need to append `?token=<value>` to the URL. Not currently configured, but the NixOS module should forward it if set.
- **Message format stability:** The WebSocket initial dump format has been stable across z2m v1.x and v2.x. The `{"topic": ..., "payload": ...}` envelope is the same format used by the MQTT layer.
