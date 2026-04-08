//! Z2m bridge client used by the provisioner. Wraps rumqttc with two
//! features the daemon doesn't need:
//!
//!   * **Inventory fetch.** `fetch_groups` / `fetch_devices` re-subscribe
//!     to the relevant retained-message topics and parse the JSON list
//!     payload z2m publishes there. Re-subscribing is the trick to force
//!     mosquitto to redeliver the retained message after the first read.
//!
//!   * **Request/response correlation.** z2m publishes responses on
//!     `bridge/response/...` and tags them with the `transaction` field
//!     from the request. We allocate a unique txn id per request and
//!     park a oneshot waiting for the matching response.
//!
//! Same shape as the Python `Z2mClient` in `pkg/hue-setup/hue_setup.py`,
//! just with tokio primitives instead of threading.Event / Lock.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use rumqttc::{AsyncClient, EventLoop, MqttOptions, QoS};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;
use tokio::sync::{Mutex, Notify, oneshot};

use crate::config::scenes::Scene;
use crate::mqtt::MqttConfig;
use crate::mqtt::codec::bridge;

/// Per-direction packet size limit. 2 MB; see `Z2mClient::connect` for
/// the rationale.
const MAX_PACKET_SIZE: usize = 2 * 1024 * 1024;

#[derive(Debug, Error)]
pub enum Z2mClientError {
    #[error("rumqttc client error: {0}")]
    Client(#[from] rumqttc::ClientError),

    #[error("mqtt connect timed out after {0:?}")]
    ConnectTimeout(Duration),

    #[error("request to {topic} timed out after {timeout:?}")]
    RequestTimeout { topic: String, timeout: Duration },

    #[error("z2m rejected request to {topic}: {message}")]
    RequestRejected { topic: String, message: String },

    #[error("payload encode failed: {0}")]
    Encode(#[from] serde_json::Error),

    #[error("retained-message fetch on {topic} timed out after {timeout:?}")]
    FetchTimeout { topic: String, timeout: Duration },

    #[error("retained payload on {topic} is not the expected JSON shape: {detail}")]
    BadPayload { topic: String, detail: String },
}

/// Bridge response envelope. z2m sends `{"status":"ok"|"error","data":...,
/// "error":"...","transaction":"..."}`.
#[derive(Debug, Clone, Deserialize)]
struct Z2mResponse {
    status: String,
    #[allow(dead_code)]
    data: Option<Value>,
    error: Option<String>,
    transaction: Option<String>,
}

/// One device entry from `bridge/devices`. Same shape z2m publishes;
/// extra fields are ignored.
#[derive(Debug, Clone, Deserialize)]
pub struct ExistingDevice {
    pub ieee_address: String,
    pub friendly_name: String,
}

/// One member entry inside an existing group.
#[derive(Debug, Clone, Deserialize)]
pub struct ExistingMember {
    pub ieee_address: String,
    pub endpoint: u32,
}

impl ExistingMember {
    pub fn as_key(&self) -> String {
        format!("{}/{}", self.ieee_address, self.endpoint)
    }
}

/// One scene entry inside an existing group.
#[derive(Debug, Clone, Deserialize)]
pub struct ExistingScene {
    pub id: u8,
    pub name: String,
}

/// One group from `bridge/groups`.
#[derive(Debug, Clone, Deserialize)]
pub struct ExistingGroup {
    pub id: u8,
    pub friendly_name: String,
    #[serde(default)]
    pub members: Vec<ExistingMember>,
    #[serde(default)]
    pub scenes: Vec<ExistingScene>,
}

/// Shared state used by the spawned event-loop task to fan out messages
/// to waiters.
struct Shared {
    /// Pending request waiters keyed by transaction id.
    requests: Mutex<HashMap<String, oneshot::Sender<Z2mResponse>>>,

    /// Latest payload received per topic, plus a Notify the event loop
    /// fires whenever the payload changes. Lets `fetch_retained` either
    /// pick up an already-arrived retained message immediately or wait
    /// for the next delivery without races. Mirrors how the python
    /// `Z2mClient` stored `_groups_payload` + `_groups_event`, but
    /// generalized to any topic instead of two hardcoded ones.
    topic_cache: Mutex<HashMap<String, TopicCacheEntry>>,
}

#[derive(Default)]
struct TopicCacheEntry {
    payload: Option<Vec<u8>>,
    notify: Arc<Notify>,
}

/// MQTT request/response client used by the provisioner.
pub struct Z2mClient {
    client: AsyncClient,
    shared: Arc<Shared>,
    txn_counter: AtomicU64,
    timeout: Duration,
}

impl Z2mClient {
    /// Connect, subscribe to the bridge topics we'll need, and start
    /// the event-loop task.
    ///
    /// We eagerly subscribe to `bridge/groups`, `bridge/devices`, and
    /// `bridge/response/#` here so the broker delivers any retained
    /// messages right away — `fetch_groups` / `fetch_devices` then read
    /// from the topic cache (or wait for the next delivery via the
    /// per-topic Notify). Mirrors the python `_on_connect` shape; we
    /// previously deferred subscribes until fetch time, which produced
    /// a subtle race against rumqttc's outgoing-request queue and made
    /// fetches time out against real mosquitto.
    pub async fn connect(config: MqttConfig, timeout: Duration) -> Result<Self, Z2mClientError> {
        let mut opts = MqttOptions::new(&config.client_id, &config.host, config.port);
        opts.set_credentials(&config.user, &config.password);
        opts.set_keep_alive(config.keep_alive);
        opts.set_inflight(20);
        // rumqttc's default max packet size is 10 KB, which is far too
        // small for z2m's `bridge/devices` retained payload — that's
        // ~200 KB on a 50-device mesh and grows with the inventory.
        // When the eventloop hits a too-big incoming packet it errors
        // out without dispatching the publish, so the topic cache
        // never gets the payload and fetches time out. 2 MB is well
        // above any plausible z2m payload.
        opts.set_max_packet_size(MAX_PACKET_SIZE, MAX_PACKET_SIZE);

        let (client, eventloop) = AsyncClient::new(opts, 100);

        let shared = Arc::new(Shared {
            requests: Mutex::new(HashMap::new()),
            topic_cache: Mutex::new(HashMap::new()),
        });
        // Pre-create the topic cache entries so the fetch path always
        // finds an Arc<Notify> to wait on, even if the eventloop hasn't
        // received any publishes yet.
        {
            let mut guard = shared.topic_cache.lock().await;
            for topic in [bridge::GROUPS, bridge::DEVICES] {
                guard.insert(topic.to_string(), TopicCacheEntry::default());
            }
        }

        let shared_for_loop = shared.clone();

        // Spawn the event loop FIRST, then queue subscribes. rumqttc's
        // AsyncClient::subscribe just enqueues a request on the outgoing
        // channel; the eventloop has to be polling to drain that channel
        // and actually send the SUBSCRIBE packet. Spawning the loop
        // first guarantees the queue gets drained as soon as we add to it.
        let connect_signal = Arc::new(tokio::sync::Notify::new());
        let connect_signal_for_loop = connect_signal.clone();
        tokio::spawn(run_event_loop(
            eventloop,
            shared_for_loop,
            connect_signal_for_loop,
        ));

        // Wait for CONNACK before issuing subscribes — until then,
        // rumqttc holds back the outgoing queue.
        match tokio::time::timeout(timeout, connect_signal.notified()).await {
            Ok(()) => {}
            Err(_) => return Err(Z2mClientError::ConnectTimeout(timeout)),
        }

        // Subscribe to all the bridge topics we care about. The broker
        // delivers any retained messages right after the SUBACK; the
        // eventloop's Publish handler drops them into `topic_cache`.
        for topic in [bridge::GROUPS, bridge::DEVICES] {
            tracing::debug!(topic, "z2m-client: subscribing");
            client.subscribe(topic, QoS::AtLeastOnce).await?;
        }
        client
            .subscribe(format!("{}#", bridge::RESPONSE_PREFIX), QoS::AtLeastOnce)
            .await?;

        Ok(Self {
            client,
            shared,
            txn_counter: AtomicU64::new(1),
            timeout,
        })
    }

    pub async fn shutdown(&self) {
        let _ = self.client.disconnect().await;
    }

    fn next_txn(&self) -> String {
        let n = self.txn_counter.fetch_add(1, Ordering::Relaxed);
        format!("hue-controller-{n}")
    }

    /// Publish a `bridge/request/...` payload with a fresh transaction
    /// id and wait for the matching `bridge/response/...` reply.
    async fn request(&self, topic: &str, body: Value) -> Result<Z2mResponse, Z2mClientError> {
        let txn = self.next_txn();
        let mut body = body;
        body.as_object_mut()
            .expect("request body is always an object")
            .insert("transaction".into(), Value::String(txn.clone()));

        let (tx, rx) = oneshot::channel();
        self.shared.requests.lock().await.insert(txn.clone(), tx);

        let payload = serde_json::to_vec(&body)?;
        self.client
            .publish(topic, QoS::AtLeastOnce, false, payload)
            .await?;

        let resp = match tokio::time::timeout(self.timeout, rx).await {
            Ok(Ok(resp)) => resp,
            Ok(Err(_)) => {
                self.shared.requests.lock().await.remove(&txn);
                return Err(Z2mClientError::RequestRejected {
                    topic: topic.to_string(),
                    message: "z2m client dropped the response channel".into(),
                });
            }
            Err(_) => {
                self.shared.requests.lock().await.remove(&txn);
                return Err(Z2mClientError::RequestTimeout {
                    topic: topic.to_string(),
                    timeout: self.timeout,
                });
            }
        };

        if resp.status != "ok" {
            return Err(Z2mClientError::RequestRejected {
                topic: topic.to_string(),
                message: resp.error.unwrap_or_else(|| "unknown error".into()),
            });
        }
        Ok(resp)
    }

    /// Read the latest payload received on `topic`. If a payload is
    /// already cached (because the broker delivered the retained
    /// message right after we subscribed at connect time), this
    /// returns immediately. Otherwise we wait up to `self.timeout`
    /// for the next delivery on the topic.
    ///
    /// `force_refresh` triggers an unsubscribe+subscribe cycle to make
    /// the broker re-deliver the retained message. Used by
    /// `fetch_*_fresh` after a mutation, when the cached copy is
    /// known stale.
    async fn fetch_retained(
        &self,
        topic: &str,
        force_refresh: bool,
    ) -> Result<Vec<u8>, Z2mClientError> {
        // Snapshot the cache entry — get a Notify clone to wait on,
        // and check whether a payload is already there.
        let (notify, cached_now) = {
            let mut guard = self.shared.topic_cache.lock().await;
            let entry = guard
                .entry(topic.to_string())
                .or_insert_with(TopicCacheEntry::default);
            let cached_now = if force_refresh {
                entry.payload.take()
            } else {
                entry.payload.clone()
            };
            (entry.notify.clone(), cached_now)
        };

        if let Some(payload) = cached_now {
            tracing::debug!(topic, bytes = payload.len(), "z2m-client: cache hit");
            return Ok(payload);
        }

        // Set up the wait BEFORE we trigger the refresh. tokio::Notify
        // stores up to one permit, so even if the broker delivers the
        // retained message between this point and our await, we won't
        // miss it.
        let waiter = notify.notified();
        tokio::pin!(waiter);

        if force_refresh {
            tracing::debug!(topic, "z2m-client: forcing refresh via unsubscribe+subscribe");
            // Unsubscribe + subscribe forces mosquitto to re-deliver
            // the retained message even if we were already subscribed.
            let _ = self.client.unsubscribe(topic).await;
            self.client.subscribe(topic, QoS::AtLeastOnce).await?;
        }
        tracing::debug!(topic, "z2m-client: waiting for delivery");

        match tokio::time::timeout(self.timeout, waiter).await {
            Ok(()) => {
                // Notify fired — read the payload back out of the cache.
                let guard = self.shared.topic_cache.lock().await;
                if let Some(entry) = guard.get(topic)
                    && let Some(payload) = &entry.payload
                {
                    tracing::debug!(
                        topic,
                        bytes = payload.len(),
                        "z2m-client: delivery received"
                    );
                    return Ok(payload.clone());
                }
                // Notify fired but cache is empty — shouldn't happen, but
                // surface it as a timeout so the retry loop kicks in.
                Err(Z2mClientError::FetchTimeout {
                    topic: topic.to_string(),
                    timeout: self.timeout,
                })
            }
            Err(_) => Err(Z2mClientError::FetchTimeout {
                topic: topic.to_string(),
                timeout: self.timeout,
            }),
        }
    }

    /// Read the current group inventory. Uses the cached payload if
    /// available; otherwise waits for the broker to deliver the
    /// retained message after our connect-time subscribe.
    pub async fn fetch_groups(&self) -> Result<Vec<ExistingGroup>, Z2mClientError> {
        self.fetch_groups_inner(false).await
    }

    /// Force a fresh re-delivery of bridge/groups via unsubscribe+
    /// subscribe. Used after a mutation that invalidates the cache
    /// (group create/rename/remove).
    pub async fn fetch_groups_fresh(&self) -> Result<Vec<ExistingGroup>, Z2mClientError> {
        self.fetch_groups_inner(true).await
    }

    async fn fetch_groups_inner(
        &self,
        force_refresh: bool,
    ) -> Result<Vec<ExistingGroup>, Z2mClientError> {
        let payload = self.fetch_retained(bridge::GROUPS, force_refresh).await?;
        serde_json::from_slice(&payload).map_err(|e| Z2mClientError::BadPayload {
            topic: bridge::GROUPS.into(),
            detail: e.to_string(),
        })
    }

    /// Read the current device inventory.
    pub async fn fetch_devices(&self) -> Result<Vec<ExistingDevice>, Z2mClientError> {
        let payload = self.fetch_retained(bridge::DEVICES, false).await?;
        // z2m may include partial entries; tolerate them by filtering.
        let raw: Value = serde_json::from_slice(&payload).map_err(|e| {
            Z2mClientError::BadPayload {
                topic: bridge::DEVICES.into(),
                detail: e.to_string(),
            }
        })?;
        let array = raw
            .as_array()
            .ok_or_else(|| Z2mClientError::BadPayload {
                topic: bridge::DEVICES.into(),
                detail: "expected JSON array".into(),
            })?;
        let mut out = Vec::with_capacity(array.len());
        for entry in array {
            let Some(obj) = entry.as_object() else { continue };
            let (Some(ieee), Some(name)) = (
                obj.get("ieee_address").and_then(|v| v.as_str()),
                obj.get("friendly_name").and_then(|v| v.as_str()),
            ) else {
                continue;
            };
            out.push(ExistingDevice {
                ieee_address: ieee.to_string(),
                friendly_name: name.to_string(),
            });
        }
        Ok(out)
    }

    pub async fn rename_device(&self, current: &str, new: &str) -> Result<(), Z2mClientError> {
        self.request(
            "zigbee2mqtt/bridge/request/device/rename",
            serde_json::json!({
                "from": current,
                "to": new,
                "homeassistant_rename": true,
            }),
        )
        .await?;
        Ok(())
    }

    pub async fn add_group(&self, friendly_name: &str, id: u8) -> Result<(), Z2mClientError> {
        self.request(
            "zigbee2mqtt/bridge/request/group/add",
            serde_json::json!({
                "friendly_name": friendly_name,
                "id": id.to_string(),
            }),
        )
        .await?;
        Ok(())
    }

    pub async fn rename_group(&self, current: &str, new: &str) -> Result<(), Z2mClientError> {
        self.request(
            "zigbee2mqtt/bridge/request/group/rename",
            serde_json::json!({
                "from": current,
                "to": new,
            }),
        )
        .await?;
        Ok(())
    }

    pub async fn remove_group(&self, friendly_name: &str, force: bool) -> Result<(), Z2mClientError> {
        self.request(
            "zigbee2mqtt/bridge/request/group/remove",
            serde_json::json!({
                "id": friendly_name,
                "force": force,
            }),
        )
        .await?;
        Ok(())
    }

    pub async fn add_member(
        &self,
        group: &str,
        device: &str,
        endpoint: u32,
    ) -> Result<(), Z2mClientError> {
        self.request(
            "zigbee2mqtt/bridge/request/group/members/add",
            serde_json::json!({
                "group": group,
                "device": device,
                "endpoint": endpoint,
            }),
        )
        .await?;
        Ok(())
    }

    pub async fn remove_member(
        &self,
        group: &str,
        device: &str,
        endpoint: u32,
    ) -> Result<(), Z2mClientError> {
        self.request(
            "zigbee2mqtt/bridge/request/group/members/remove",
            serde_json::json!({
                "group": group,
                "device": device,
                "endpoint": endpoint,
            }),
        )
        .await?;
        Ok(())
    }

    /// Issue a `scene_add` to the given group's `/set` topic. Same epsilon
    /// trick as the python version: we add 1e-4 to the transition so
    /// `Number.isInteger` returns false on the JS side and z2m routes to
    /// `enhancedAdd` (the only path Hue bulbs honour).
    pub async fn add_scene(&self, group: &str, scene: &Scene) -> Result<(), Z2mClientError> {
        let payload = SceneAddPayload::from(scene);
        let body = serde_json::json!({ "scene_add": payload });
        let topic = format!("zigbee2mqtt/{group}/set");
        self.client
            .publish(&topic, QoS::AtLeastOnce, false, serde_json::to_vec(&body)?)
            .await?;
        Ok(())
    }

    /// Read a device's current state via its retained
    /// `zigbee2mqtt/<friendly_name>` topic. Returns `None` if no retained
    /// state is available within the timeout.
    ///
    /// Unlike `bridge/devices` and `bridge/groups`, per-device state
    /// topics aren't pre-subscribed at connect time (we don't know which
    /// devices the caller will want until reconcile_devices runs). We
    /// subscribe lazily here, then fall through to the same cache+notify
    /// path as the bridge fetches.
    pub async fn fetch_device_state(
        &self,
        friendly_name: &str,
    ) -> Result<Option<Value>, Z2mClientError> {
        let topic = format!("zigbee2mqtt/{friendly_name}");

        // Subscribe so the broker delivers the retained payload (if any)
        // and any subsequent updates flow into the cache. Idempotent:
        // re-subscribing to an already-subscribed topic is fine and
        // re-triggers retained delivery.
        self.client
            .subscribe(&topic, QoS::AtLeastOnce)
            .await?;

        match self.fetch_retained(&topic, false).await {
            Ok(payload) => {
                let parsed = serde_json::from_slice(&payload).map_err(|e| {
                    Z2mClientError::BadPayload {
                        topic: topic.clone(),
                        detail: e.to_string(),
                    }
                })?;
                Ok(Some(parsed))
            }
            Err(Z2mClientError::FetchTimeout { .. }) => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// Write a single set of options to a device's `/set` topic. Same
    /// shape as the python `set_device_options`.
    pub async fn set_device_options(
        &self,
        friendly_name: &str,
        options: &Value,
    ) -> Result<(), Z2mClientError> {
        let topic = format!("zigbee2mqtt/{friendly_name}/set");
        self.client
            .publish(&topic, QoS::AtLeastOnce, false, serde_json::to_vec(options)?)
            .await?;
        Ok(())
    }
}

/// Wire body for `scene_add`. Constructed from a [`Scene`]; the
/// transition gets the +1e-4 epsilon so the value serializes as a float
/// rather than an integer (which steers z2m's converter into the
/// `enhancedAdd` path).
#[derive(Debug, Serialize)]
struct SceneAddPayload {
    #[serde(rename = "ID")]
    id: u8,
    name: String,
    transition: f64,
    state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    brightness: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    color_temp: Option<u16>,
}

impl From<&Scene> for SceneAddPayload {
    fn from(s: &Scene) -> Self {
        Self {
            id: s.id,
            name: s.name.clone(),
            transition: s.transition + 1e-4,
            state: s.state.clone(),
            brightness: s.brightness,
            color_temp: s.color_temp,
        }
    }
}

async fn run_event_loop(
    mut eventloop: EventLoop,
    shared: Arc<Shared>,
    connect_signal: Arc<tokio::sync::Notify>,
) {
    let mut signaled = false;
    loop {
        match eventloop.poll().await {
            Ok(rumqttc::Event::Incoming(rumqttc::Packet::ConnAck(_))) => {
                if !signaled {
                    connect_signal.notify_one();
                    signaled = true;
                }
            }
            Ok(rumqttc::Event::Incoming(rumqttc::Packet::Publish(p))) => {
                let topic = p.topic.clone();
                tracing::debug!(
                    topic = %topic,
                    bytes = p.payload.len(),
                    retain = p.retain,
                    "z2m-client: received publish"
                );
                if topic.starts_with(bridge::RESPONSE_PREFIX) {
                    if let Ok(resp) = serde_json::from_slice::<Z2mResponse>(&p.payload) {
                        if let Some(txn) = &resp.transaction {
                            let waiter = {
                                let mut guard = shared.requests.lock().await;
                                guard.remove(txn)
                            };
                            if let Some(tx) = waiter {
                                let _ = tx.send(resp);
                            }
                        }
                    }
                    continue;
                }
                // General topic-cache dispatch. Update the cache entry
                // and fire its Notify so any pending fetch_retained
                // wakes up.
                let notify = {
                    let mut guard = shared.topic_cache.lock().await;
                    let entry = guard
                        .entry(topic.clone())
                        .or_insert_with(TopicCacheEntry::default);
                    entry.payload = Some(p.payload.to_vec());
                    entry.notify.clone()
                };
                notify.notify_waiters();
            }
            Ok(_) => {}
            Err(e) => {
                tracing::warn!(error = ?e, "z2m client event loop error; retrying after 1s");
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }
}
