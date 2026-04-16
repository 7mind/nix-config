//! MQTT bridge: parses incoming z2m messages into [`crate::domain::Event`],
//! exposes thin pub/sub helpers (publish_group_set, publish_device_set,
//! publish_raw) that the [`crate::effect_dispatch`] module calls to
//! translate typed [`crate::domain::Effect`]s into wire-level publishes,
//! and drives the rumqttc event loop.
//!
//! Architecture:
//!
//!   * [`MqttBridge`] is the public handle. Construct via
//!     [`MqttBridge::start`], which connects to the broker, subscribes to
//!     all the topics the topology cares about, spawns a tokio task to
//!     drive the rumqttc event loop, and hands back:
//!       - the bridge handle (for publishing actions and `/get` queries)
//!       - an `mpsc::Receiver<Event>` the daemon's main loop polls
//!
//!   * The event loop runs in its own tokio task. It owns the rumqttc
//!     `EventLoop` and forwards every parseable Publish into the channel
//!     as an [`Event`]. Unrelated MQTT control packets (PingResp, etc)
//!     are silently ignored.
//!
//!   * Outbound publishes go through the `AsyncClient` clone the bridge
//!     holds. They're awaitable and bubble up [`MqttError`] on failure.
//!
//! ## Topic conventions
//!
//! z2m publishes to:
//!   - `zigbee2mqtt/<friendly_name>/action` for switch button action
//!     codes (plain text payload like `"on_press_release"`)
//!   - `zigbee2mqtt/<friendly_name>` for device state (motion sensors)
//!     and group state (z2m aggregates member states into per-group state)
//!
//! We dispatch by suffix:
//!   - `/action` → resolve via the device's switch model descriptor
//!   - bare → look up in motion sensor / group indexes

pub mod codec;
mod parse;
pub mod topics;

use std::sync::Arc;
use std::time::Duration;

use rumqttc::{AsyncClient, EventLoop, MqttOptions, QoS};
use thiserror::Error;
use tokio::sync::mpsc;

use crate::domain::action::Payload;
use crate::domain::event::Event;
use crate::time::Clock;
use crate::topology::Topology;

/// MQTT connection parameters.
#[derive(Debug, Clone)]
pub struct MqttConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub client_id: String,
    pub keep_alive: Duration,
}

impl MqttConfig {
    pub fn new(
        host: impl Into<String>,
        port: u16,
        user: impl Into<String>,
        password: impl Into<String>,
        client_id: impl Into<String>,
    ) -> Self {
        Self {
            host: host.into(),
            port,
            user: user.into(),
            password: password.into(),
            client_id: client_id.into(),
            keep_alive: Duration::from_secs(30),
        }
    }

    /// Build a configured `(AsyncClient, EventLoop)` pair using this
    /// connection profile. `inflight` is the in-flight QoS>0 publish
    /// window (daemon bursts /get during startup, provisioner is more
    /// sequential). `channel_cap` is the rumqttc command-channel size.
    ///
    /// Both mqtt-controller modes (daemon, provisioner) share these
    /// settings: same broker, same credentials, same packet-size limit
    /// (large enough for z2m's bridge inventory payloads).
    pub fn build_client(&self, inflight: u16, channel_cap: usize) -> (AsyncClient, EventLoop) {
        let mut opts = MqttOptions::new(&self.client_id, &self.host, self.port);
        opts.set_credentials(&self.user, &self.password);
        opts.set_keep_alive(self.keep_alive);
        opts.set_inflight(inflight);
        // rumqttc defaults to 10 KB max incoming packet which is far too
        // small for z2m bridge inventory payloads (~200 KB on a 50-device
        // mesh) and could also bite on large group state messages. 2 MB
        // is well above any plausible z2m payload.
        opts.set_max_packet_size(MAX_PACKET_SIZE, MAX_PACKET_SIZE);
        AsyncClient::new(opts, channel_cap)
    }
}

/// Per-direction packet size limit shared by daemon and provisioner.
pub const MAX_PACKET_SIZE: usize = 2 * 1024 * 1024;

#[derive(Debug, Error)]
pub enum MqttError {
    #[error("rumqttc client error: {0}")]
    Client(#[from] rumqttc::ClientError),

    #[error("payload serialize failed: {0}")]
    Serialize(#[from] serde_json::Error),
}

/// Public handle. Holds the MQTT client and the topology used for parsing.
/// The clock is consumed by the spawned event loop only; it isn't stored
/// on the bridge.
#[derive(Clone)]
pub struct MqttBridge {
    client: AsyncClient,
    topology: Arc<Topology>,
}

impl MqttBridge {
    /// Connect, subscribe, and spawn the event-loop task.
    ///
    /// On success returns the bridge handle plus a `Receiver<Event>` the
    /// daemon's main loop polls. The event-loop task runs until the
    /// channel is dropped (i.e. when the daemon shuts down).
    pub async fn start(
        config: MqttConfig,
        topology: Arc<Topology>,
        clock: Arc<dyn Clock>,
    ) -> Result<(Self, mpsc::Receiver<Event>), MqttError> {
        // Inflight 50 covers the /get burst during startup state refresh;
        // channel cap 256 buffers the daemon's outbound action stream.
        let (client, eventloop) = config.build_client(50, 256);

        // Subscribe to every topic we care about. Doing this BEFORE
        // spawning the event loop ensures the SUBACKs come in once
        // polling starts; rumqttc queues the subscribe commands.
        Self::subscribe_all(&client, &topology).await?;

        let (tx, rx) = mpsc::channel(512);
        let client_for_loop = client.clone();
        let topology_for_loop = topology.clone();
        tokio::spawn(run_eventloop(eventloop, client_for_loop, tx, topology_for_loop, clock));

        Ok((Self { client, topology }, rx))
    }

    async fn subscribe_all(
        client: &AsyncClient,
        topology: &Topology,
    ) -> Result<(), MqttError> {
        subscribe_all_topics(client, topology).await
    }

    /// Publish a payload to `zigbee2mqtt/<group>/set` for a z2m group.
    pub async fn publish_group_set(
        &self,
        group_name: &str,
        payload: &Payload,
    ) -> Result<(), MqttError> {
        let topic = topics::set_topic(group_name);
        let bytes = serde_json::to_vec(payload)?;
        self.client
            .publish(topic, QoS::AtLeastOnce, false, bytes)
            .await?;
        Ok(())
    }

    /// Publish a payload to a device's `/set` topic. Translates the
    /// payload to the Z-Wave JS UI wire format when `is_zwave` is set.
    pub async fn publish_device_set(
        &self,
        device_name: &str,
        payload: &Payload,
        is_zwave: bool,
    ) -> Result<(), MqttError> {
        if is_zwave {
            let on = match payload {
                Payload::DeviceStateSet { state } => *state == "ON",
                other => {
                    tracing::warn!(
                        device = device_name,
                        payload = ?other,
                        "unexpected payload type for zwave plug; ignoring"
                    );
                    return Ok(());
                }
            };
            let topic = topics::zwave_switch_set_topic(device_name);
            let bytes: &[u8] = if on { b"true" } else { b"false" };
            self.client
                .publish(topic, QoS::AtLeastOnce, false, bytes)
                .await?;
        } else {
            let topic = topics::set_topic(device_name);
            let bytes = serde_json::to_vec(payload)?;
            self.client
                .publish(topic, QoS::AtLeastOnce, false, bytes)
                .await?;
        }
        Ok(())
    }

    /// Publish raw bytes to an arbitrary MQTT topic. Used by the
    /// effect dispatcher for HA discovery configs and state updates.
    pub async fn publish_raw(
        &self,
        topic: &str,
        bytes: &[u8],
        retain: bool,
    ) -> Result<(), MqttError> {
        self.client
            .publish(topic, QoS::AtLeastOnce, retain, bytes.to_vec())
            .await?;
        Ok(())
    }

    /// Publish a `{"state": ""}` to `<name>/get` to force z2m to query
    /// the current state and re-publish it on the matching state topic.
    /// Used by the startup state refresh for groups and Zigbee plugs
    /// whose retained messages didn't arrive.
    pub async fn publish_get(&self, name: &str) -> Result<(), MqttError> {
        let topic = topics::get_topic(name);
        self.client
            .publish(topic, QoS::AtLeastOnce, false, br#"{"state":""}"#.as_slice())
            .await?;
        Ok(())
    }

    /// Request a fresh value publish for a Z-Wave node's binary switch
    /// state. Publishes a `writeValue` API call that reads (not writes)
    /// the current value, causing Z-Wave JS UI to re-publish the
    /// `currentValue` topic.
    ///
    /// Z-Wave JS UI doesn't support the zigbee2mqtt-style `<topic>/get`
    /// pattern, so we use the MQTT API's `refreshValues` command instead.
    pub async fn publish_zwave_refresh(
        &self,
        node_id: u16,
    ) -> Result<(), MqttError> {
        let topic = format!(
            "{}refreshValues/set",
            crate::mqtt::codec::zwave_api::GATEWAY_PREFIX,
        );
        let payload = serde_json::json!({"args": [node_id]});
        self.client
            .publish(topic, QoS::AtLeastOnce, false, serde_json::to_vec(&payload)?)
            .await?;
        Ok(())
    }

    /// Publish a `/get` for TRV climate attributes that the heating
    /// controller needs: temperature, demand, running state, setpoint.
    /// Unlike `publish_get` which sends `{"state":""}`, this queries
    /// the specific climate attributes Bosch BTH-RA exposes.
    pub async fn publish_get_trv(&self, name: &str) -> Result<(), MqttError> {
        let topic = topics::get_topic(name);
        let payload = br#"{"local_temperature":"","pi_heating_demand":"","running_state":"","occupied_heating_setpoint":"","operating_mode":"","battery":""}"#;
        self.client
            .publish(topic, QoS::AtLeastOnce, false, payload.as_slice())
            .await?;
        Ok(())
    }

    /// Borrow the topology — useful when the caller already has the
    /// bridge but needs to enumerate groups for the state-refresh logic.
    pub fn topology(&self) -> &Arc<Topology> {
        &self.topology
    }
}

async fn run_eventloop(
    mut eventloop: EventLoop,
    client: AsyncClient,
    tx: mpsc::Sender<Event>,
    topology: Arc<Topology>,
    clock: Arc<dyn Clock>,
) {
    let mut initial_connect = true;

    loop {
        match eventloop.poll().await {
            Ok(rumqttc::Event::Incoming(rumqttc::Packet::ConnAck(_))) => {
                if initial_connect {
                    initial_connect = false;
                    tracing::info!("mqtt: initial connection established");
                } else {
                    // Reconnect after broker restart. With clean_session=true
                    // the broker discards our subscriptions, so re-subscribe.
                    tracing::warn!("mqtt: reconnected after connection loss; re-subscribing");
                    if let Err(e) = subscribe_all_topics(&client, &topology).await {
                        tracing::error!(error = ?e, "mqtt: failed to re-subscribe after reconnect");
                    }
                }
            }
            Ok(rumqttc::Event::Incoming(rumqttc::Packet::Publish(p))) => {
                if let Some(event) = parse::parse_event(&topology, &p, &*clock) {
                    if tx.send(event).await.is_err() {
                        break;
                    }
                }
            }
            Ok(_) => {}
            Err(e) => {
                tracing::warn!(error = ?e, "mqtt event loop error; retrying after 1s");
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }
}

/// Subscribe to all MQTT topics the topology requires. Used on initial
/// connect and on every reconnect.
async fn subscribe_all_topics(
    client: &AsyncClient,
    topology: &Topology,
) -> Result<(), MqttError> {
    for sw in topology.all_switch_device_names() {
        client.subscribe(topics::device_action_topic(sw), QoS::AtLeastOnce).await?;
    }
    for sensor in topology.all_motion_sensor_names() {
        client.subscribe(topics::state_topic(sensor), QoS::AtLeastOnce).await?;
    }
    for group in topology.all_group_names() {
        client.subscribe(topics::state_topic(group), QoS::AtLeastOnce).await?;
    }
    for plug in topology.all_plug_names() {
        if !topology.is_zwave_plug(plug) {
            client.subscribe(topics::state_topic(plug), QoS::AtLeastOnce).await?;
        }
    }
    for trv in topology.all_trv_names() {
        client.subscribe(topics::state_topic(trv), QoS::AtLeastOnce).await?;
    }
    for wt in topology.all_wall_thermostat_names() {
        client.subscribe(topics::state_topic(wt), QoS::AtLeastOnce).await?;
    }
    for plug in topology.zwave_plug_names() {
        client.subscribe(topics::zwave_switch_state_topic(plug), QoS::AtLeastOnce).await?;
        client.subscribe(topics::zwave_meter_power_topic(plug), QoS::AtLeastOnce).await?;
    }
    Ok(())
}



#[cfg(test)]
mod tests;
