//! Low-level Z-Wave JS UI MQTT API client. Shared between the provisioner
//! (rename / relocate nodes) and the daemon startup seed (bulk-fetch
//! current node values).
//!
//! API pattern: request on `zwave/_CLIENTS/ZWAVE_GATEWAY-zwave/api/<cmd>/set`,
//! response on `zwave/_CLIENTS/ZWAVE_GATEWAY-zwave/api/<cmd>`. No
//! transaction IDs — subscribe to the response topic first, then
//! publish the request, then wait for the next publish on it.
//!
//! This client opens its own short-lived MQTT connection; it does not
//! share the daemon's long-lived [`crate::mqtt::MqttBridge`] because the
//! bridge is subscribed to `zwave/#` and runs its incoming stream
//! through the event parser — piping API responses through that layer
//! would add unnecessary state.

use std::time::Duration;

use rumqttc::{AsyncClient, MqttOptions, QoS};
use serde_json::Value;

use super::codec::{zwave_api, zwave_meter};
use super::topics;
use super::MqttConfig;

/// One Z-Wave node as reported by the `getNodes` API. Carries the name,
/// location, and the two values the daemon cares about: switch state
/// and meter power. Additional CC values are ignored — if you need them,
/// extend the parser below.
#[derive(Debug, Clone, PartialEq)]
pub struct ZwaveNode {
    pub node_id: u16,
    /// The `name` field as reported by ZJS-UI, defaulting to
    /// `"nodeID_<n>"` when unset (matches ZJS-UI's own convention).
    pub current_name: String,
    /// The `loc` field; empty string if unset.
    pub current_location: String,
    /// Latest cached `switch_binary/currentValue` at endpoint 0, or
    /// `None` if the node doesn't expose one or the value hasn't been
    /// observed yet.
    pub switch_on: Option<bool>,
    /// Latest cached `meter/endpoint_0/value/66049` (watts), or `None`.
    pub power_w: Option<f64>,
}

/// Short-lived MQTT client scoped to one or more Z-Wave JS UI API calls.
pub struct ZwaveApiClient {
    client: AsyncClient,
    eventloop: rumqttc::EventLoop,
}

impl ZwaveApiClient {
    /// Connect and wait for CONNACK. Fails if the broker is unreachable
    /// or doesn't reply within `timeout`.
    pub async fn connect(
        mqtt_config: &MqttConfig,
        timeout: Duration,
    ) -> anyhow::Result<Self> {
        let mut opts = MqttOptions::new(
            format!("mqtt-controller-zwave-api-{}", uuid::Uuid::new_v4()),
            &mqtt_config.host,
            mqtt_config.port,
        );
        opts.set_credentials(&mqtt_config.user, &mqtt_config.password);
        opts.set_keep_alive(mqtt_config.keep_alive);
        opts.set_inflight(20);
        opts.set_max_packet_size(2 * 1024 * 1024, 2 * 1024 * 1024);

        let (client, mut eventloop) = AsyncClient::new(opts, 100);

        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            match tokio::time::timeout(remaining, eventloop.poll()).await {
                Ok(Ok(rumqttc::Event::Incoming(rumqttc::Packet::ConnAck(_)))) => break,
                Ok(Ok(_)) => continue,
                Ok(Err(e)) => anyhow::bail!("zwave mqtt connect error: {e}"),
                Err(_) => anyhow::bail!("zwave mqtt connect timed out"),
            }
        }

        Ok(Self { client, eventloop })
    }

    pub async fn disconnect(self) {
        let _ = self.client.disconnect().await;
    }

    /// Call `getNodes` and parse the response. Returns every node the
    /// gateway knows about, including offline/sleeping ones (ZJS-UI's
    /// cache is authoritative for initial seed).
    pub async fn get_nodes(&mut self, timeout: Duration) -> anyhow::Result<Vec<ZwaveNode>> {
        let response_topic = format!("{}getNodes", zwave_api::GATEWAY_PREFIX);
        let request_topic = format!("{}getNodes/set", zwave_api::GATEWAY_PREFIX);
        self.request(&response_topic, &request_topic, serde_json::json!({"args": []}), timeout)
            .await
            .and_then(|payload| parse_get_nodes_response(&payload))
    }

    /// Call `setNodeName`. Fails if the API returns `success: false`.
    pub async fn set_node_name(
        &mut self,
        node_id: u16,
        name: &str,
        timeout: Duration,
    ) -> anyhow::Result<()> {
        let response_topic = format!("{}setNodeName", zwave_api::GATEWAY_PREFIX);
        let request_topic = topics::zwave_api_set_node_name();
        let payload = serde_json::json!({"args": [node_id, name]});
        let resp = self
            .request(&response_topic, &request_topic, payload, timeout)
            .await?;
        expect_success(&resp).map_err(|msg| {
            anyhow::anyhow!("zwave: setNodeName failed for node {node_id}: {msg}")
        })
    }

    /// Call `setNodeLocation`.
    pub async fn set_node_location(
        &mut self,
        node_id: u16,
        location: &str,
        timeout: Duration,
    ) -> anyhow::Result<()> {
        let response_topic = format!("{}setNodeLocation", zwave_api::GATEWAY_PREFIX);
        let request_topic = format!("{}setNodeLocation/set", zwave_api::GATEWAY_PREFIX);
        let payload = serde_json::json!({"args": [node_id, location]});
        let resp = self
            .request(&response_topic, &request_topic, payload, timeout)
            .await?;
        expect_success(&resp).map_err(|msg| {
            anyhow::anyhow!("zwave: setNodeLocation failed for node {node_id}: {msg}")
        })
    }

    /// Subscribe → publish → wait for one publish on the response topic.
    /// Returns the raw response payload.
    async fn request(
        &mut self,
        response_topic: &str,
        request_topic: &str,
        payload: Value,
        timeout: Duration,
    ) -> anyhow::Result<Vec<u8>> {
        self.client
            .subscribe(response_topic, QoS::AtLeastOnce)
            .await?;
        self.wait_for_suback(timeout).await?;

        self.client
            .publish(
                request_topic,
                QoS::AtLeastOnce,
                false,
                serde_json::to_vec(&payload)?,
            )
            .await?;

        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                anyhow::bail!("zwave: {request_topic} API timed out");
            }
            match tokio::time::timeout(remaining, self.eventloop.poll()).await {
                Ok(Ok(rumqttc::Event::Incoming(rumqttc::Packet::Publish(p)))) => {
                    if p.topic == response_topic {
                        return Ok(p.payload.to_vec());
                    }
                }
                Ok(Ok(_)) => continue,
                Ok(Err(e)) => anyhow::bail!("zwave: eventloop error: {e}"),
                Err(_) => anyhow::bail!("zwave: {request_topic} API timed out"),
            }
        }
    }

    async fn wait_for_suback(&mut self, timeout: Duration) -> anyhow::Result<()> {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            match tokio::time::timeout(remaining, self.eventloop.poll()).await {
                Ok(Ok(rumqttc::Event::Incoming(rumqttc::Packet::SubAck(_)))) => return Ok(()),
                Ok(Ok(_)) => continue,
                Ok(Err(e)) => anyhow::bail!("zwave: eventloop error waiting for SUBACK: {e}"),
                Err(_) => anyhow::bail!("zwave: timed out waiting for SUBACK"),
            }
        }
    }
}

/// Check the standard `{success, message}` envelope. Returns `Ok(())`
/// on success, or the error message on failure.
fn expect_success(payload: &[u8]) -> Result<(), String> {
    let resp: Value = serde_json::from_slice(payload)
        .map_err(|e| format!("invalid JSON response: {e}"))?;
    let success = resp.get("success").and_then(|v| v.as_bool()).unwrap_or(false);
    if success {
        return Ok(());
    }
    Err(resp
        .get("message")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown error")
        .to_string())
}

/// Parse the `getNodes` response:
/// `{"success":true,"result":[{"id":..,"name":..,"loc":..,"values":{...}},...]}`.
pub fn parse_get_nodes_response(payload: &[u8]) -> anyhow::Result<Vec<ZwaveNode>> {
    let resp: Value = serde_json::from_slice(payload)?;
    let success = resp.get("success").and_then(|v| v.as_bool()).unwrap_or(false);
    if !success {
        let msg = resp
            .get("message")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown error");
        anyhow::bail!("zwave: getNodes API failed: {msg}");
    }
    let result = resp
        .get("result")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow::anyhow!("zwave: getNodes response missing 'result' array"))?;

    let mut nodes = Vec::new();
    for entry in result {
        let Some(node_id) = entry.get("id").and_then(|v| v.as_u64()) else {
            continue;
        };
        let node_id = node_id as u16;
        let raw_name = entry.get("name").and_then(|v| v.as_str()).unwrap_or("");
        let current_name = if raw_name.is_empty() {
            format!("nodeID_{node_id}")
        } else {
            raw_name.to_string()
        };
        let current_location = entry
            .get("loc")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        // Walk the `values` dict once, extract the two keys we care
        // about. ZJS-UI keys each value as
        // `<endpoint>-<cc_num>-<endpoint>-<property>[-<propertyKey>]`,
        // e.g. `"0-37-0-currentValue"` for switch_binary and
        // `"0-50-0-value-66049"` for the power meter.
        let values = entry.get("values").and_then(|v| v.as_object());
        let switch_on = values.and_then(|vs| extract_switch_on(vs));
        let power_w = values.and_then(|vs| extract_power_w(vs));

        nodes.push(ZwaveNode {
            node_id,
            current_name,
            current_location,
            switch_on,
            power_w,
        });
    }
    Ok(nodes)
}

fn extract_switch_on(values: &serde_json::Map<String, Value>) -> Option<bool> {
    // switch_binary CC = 0x25 = 37. Endpoint 0, property currentValue.
    let key = "0-37-0-currentValue";
    values.get(key)?.get("value")?.as_bool()
}

fn extract_power_w(values: &serde_json::Map<String, Value>) -> Option<f64> {
    // meter CC = 0x32 = 50. Endpoint 0, property "value", propertyKey
    // matches the scale+rate-type composite used in our other code
    // paths. See crate::mqtt::codec::zwave_meter.
    let key = format!("0-50-0-value-{}", zwave_meter::POWER_W);
    let watts = values.get(&key)?.get("value")?.as_f64()?;
    // NAS-WR01ZE can report spurious negative values; clamp to zero
    // here so the daemon's kill-switch logic sees consistent power
    // readings (same treatment as `parse_zwave_event`).
    Some(watts.max(0.0))
}

#[cfg(test)]
#[path = "zwave_api_tests.rs"]
mod tests;
