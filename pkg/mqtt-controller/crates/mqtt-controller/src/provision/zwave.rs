//! Z-Wave provisioning phase: rename Z-Wave nodes to match the desired
//! names from the device catalog.
//!
//! Z-Wave JS UI exposes its API over MQTT:
//!   - Discover nodes via `getNodes` API call.
//!   - Rename via `setNodeName` API call.
//!
//! API request/response pattern:
//!   - Request:  `zwave/_CLIENTS/ZWAVE_GATEWAY-zwave/api/<command>/set`
//!   - Response: `zwave/_CLIENTS/ZWAVE_GATEWAY-zwave/api/<command>`
//!
//! Unlike zigbee2mqtt, Z-Wave JS UI doesn't use transaction IDs for
//! request/response correlation. We subscribe to the response topic
//! before publishing the request, then wait for the next message.

use std::collections::BTreeMap;
use std::time::Duration;

use rumqttc::{AsyncClient, MqttOptions, QoS};

use crate::config::Config;
use crate::mqtt::MqttConfig;
use crate::mqtt::codec::zwave_api;
use crate::mqtt::topics;

use super::{ProvisionOptions, ReconcileSummary};

/// Discovered Z-Wave node.
#[derive(Debug)]
struct ZwaveNode {
    node_id: u16,
    current_name: String,
}

/// Reconcile Z-Wave plug names against the device catalog.
///
/// For each Z-Wave plug in the catalog (protocol == zwave), check if
/// the node's current name in Z-Wave JS UI matches the desired name
/// (the device catalog key). Rename if it doesn't.
pub async fn reconcile_zwave_names(
    config: &Config,
    mqtt_config: &MqttConfig,
    options: &ProvisionOptions,
) -> anyhow::Result<ReconcileSummary> {
    // Collect desired node_id → name mappings from the catalog.
    let mut desired: BTreeMap<u16, &str> = BTreeMap::new();
    for (name, entry) in &config.devices {
        if let Some(node_id) = entry.zwave_node_id() {
            desired.insert(node_id, name.as_str());
        }
    }

    if desired.is_empty() {
        return Ok(ReconcileSummary::default());
    }

    tracing::info!(
        zwave_plugs = desired.len(),
        "zwave: checking node names"
    );

    let mut conn = ZwaveConn::connect(mqtt_config, options.timeout).await?;

    // Discover current node names via the getNodes API.
    let nodes = conn.get_nodes(options.timeout).await?;
    let nodes_by_id: BTreeMap<u16, ZwaveNode> = nodes
        .into_iter()
        .map(|n| (n.node_id, n))
        .collect();

    let mut summary = ReconcileSummary::default();

    for (&node_id, &desired_name) in &desired {
        let Some(node) = nodes_by_id.get(&node_id) else {
            tracing::warn!(
                node_id,
                desired = desired_name,
                "zwave: node not found (offline or not paired); skipping"
            );
            continue;
        };

        if node.current_name == desired_name {
            tracing::info!(
                node_id,
                name = desired_name,
                "[skip] already named"
            );
            summary.skipped += 1;
            continue;
        }

        let verb = if options.dry_run {
            "[dry-run] would rename"
        } else {
            "rename"
        };
        tracing::info!(
            node_id,
            from = %node.current_name,
            to = desired_name,
            "zwave: {verb}"
        );

        if !options.dry_run {
            conn.set_node_name(node_id, desired_name, options.timeout).await?;
            tokio::time::sleep(options.settle * 2).await;
            summary.touched += 1;
        }
    }

    conn.disconnect().await;
    Ok(summary)
}

/// Lightweight MQTT connection for Z-Wave JS UI API calls.
struct ZwaveConn {
    client: AsyncClient,
    eventloop: rumqttc::EventLoop,
}

impl ZwaveConn {
    async fn connect(mqtt_config: &MqttConfig, timeout: Duration) -> anyhow::Result<Self> {
        let mut opts = MqttOptions::new(
            format!("mqtt-controller-zwave-provision-{}", uuid::Uuid::new_v4()),
            &mqtt_config.host,
            mqtt_config.port,
        );
        opts.set_credentials(&mqtt_config.user, &mqtt_config.password);
        opts.set_keep_alive(mqtt_config.keep_alive);
        opts.set_inflight(20);
        opts.set_max_packet_size(2 * 1024 * 1024, 2 * 1024 * 1024);

        let (client, mut eventloop) = AsyncClient::new(opts, 100);

        // Wait for CONNACK.
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

    /// Call the Z-Wave JS UI `getNodes` API and parse the response.
    async fn get_nodes(&mut self, timeout: Duration) -> anyhow::Result<Vec<ZwaveNode>> {
        let response_topic = format!("{}getNodes", zwave_api::GATEWAY_PREFIX);
        let request_topic = format!("{}getNodes/set", zwave_api::GATEWAY_PREFIX);

        // Subscribe to response topic first.
        self.client
            .subscribe(&response_topic, QoS::AtLeastOnce)
            .await?;

        // Wait for SUBACK.
        self.wait_for_suback(timeout).await?;

        // Publish the request.
        let payload = serde_json::json!({"args": []});
        self.client
            .publish(&request_topic, QoS::AtLeastOnce, false, serde_json::to_vec(&payload)?)
            .await?;

        // Wait for the response publish on the response topic.
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                anyhow::bail!("zwave: getNodes API timed out");
            }
            match tokio::time::timeout(remaining, self.eventloop.poll()).await {
                Ok(Ok(rumqttc::Event::Incoming(rumqttc::Packet::Publish(p)))) => {
                    if p.topic == response_topic {
                        return parse_get_nodes_response(&p.payload);
                    }
                }
                Ok(Ok(_)) => continue,
                Ok(Err(e)) => anyhow::bail!("zwave: eventloop error waiting for getNodes: {e}"),
                Err(_) => anyhow::bail!("zwave: getNodes API timed out"),
            }
        }
    }

    /// Call the Z-Wave JS UI `setNodeName` API.
    async fn set_node_name(
        &mut self,
        node_id: u16,
        name: &str,
        timeout: Duration,
    ) -> anyhow::Result<()> {
        let response_topic = format!("{}setNodeName", zwave_api::GATEWAY_PREFIX);
        let request_topic = topics::zwave_api_set_node_name();

        // Subscribe to response topic.
        self.client
            .subscribe(&response_topic, QoS::AtLeastOnce)
            .await?;
        self.wait_for_suback(timeout).await?;

        // Publish the rename request.
        let payload = serde_json::json!({"args": [node_id, name]});
        self.client
            .publish(&request_topic, QoS::AtLeastOnce, false, serde_json::to_vec(&payload)?)
            .await?;

        // Wait for the response.
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                anyhow::bail!("zwave: setNodeName API timed out for node {node_id}");
            }
            match tokio::time::timeout(remaining, self.eventloop.poll()).await {
                Ok(Ok(rumqttc::Event::Incoming(rumqttc::Packet::Publish(p)))) => {
                    if p.topic == response_topic {
                        let resp: serde_json::Value = serde_json::from_slice(&p.payload)?;
                        let success = resp.get("success").and_then(|v| v.as_bool()).unwrap_or(false);
                        if success {
                            return Ok(());
                        }
                        let msg = resp.get("message")
                            .and_then(|v| v.as_str())
                            .unwrap_or("unknown error");
                        anyhow::bail!("zwave: setNodeName failed for node {node_id}: {msg}");
                    }
                }
                Ok(Ok(_)) => continue,
                Ok(Err(e)) => anyhow::bail!("zwave: eventloop error during setNodeName: {e}"),
                Err(_) => anyhow::bail!("zwave: setNodeName timed out for node {node_id}"),
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

    async fn disconnect(self) {
        let _ = self.client.disconnect().await;
    }
}

/// Parse the `getNodes` API response. The response payload is:
/// `{"success":true,"message":"...","result":[{"id":1,"name":"","loc":"",...},...]}`
fn parse_get_nodes_response(payload: &[u8]) -> anyhow::Result<Vec<ZwaveNode>> {
    let resp: serde_json::Value = serde_json::from_slice(payload)?;
    let success = resp.get("success").and_then(|v| v.as_bool()).unwrap_or(false);
    if !success {
        let msg = resp.get("message")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown error");
        anyhow::bail!("zwave: getNodes API failed: {msg}");
    }

    let result = resp.get("result")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow::anyhow!("zwave: getNodes response missing 'result' array"))?;

    let mut nodes = Vec::new();
    for entry in result {
        let Some(node_id) = entry.get("id").and_then(|v| v.as_u64()) else {
            continue;
        };
        let name = entry.get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        // Use the name if set, otherwise fall back to "nodeID_N".
        let current_name = if name.is_empty() {
            format!("nodeID_{node_id}")
        } else {
            name.to_string()
        };
        nodes.push(ZwaveNode {
            node_id: node_id as u16,
            current_name,
        });
    }
    Ok(nodes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_get_nodes_success() {
        let payload = br#"{
            "success": true,
            "message": "Success",
            "result": [
                {"id": 1, "name": "", "loc": ""},
                {"id": 6, "name": "Plug4", "loc": ""}
            ]
        }"#;
        let nodes = parse_get_nodes_response(payload).unwrap();
        assert_eq!(nodes.len(), 2);
        assert_eq!(nodes[0].node_id, 1);
        assert_eq!(nodes[0].current_name, "nodeID_1");
        assert_eq!(nodes[1].node_id, 6);
        assert_eq!(nodes[1].current_name, "Plug4");
    }

    #[test]
    fn parse_get_nodes_failure() {
        let payload = br#"{"success": false, "message": "gateway offline"}"#;
        let err = parse_get_nodes_response(payload).unwrap_err();
        assert!(err.to_string().contains("gateway offline"));
    }

    #[test]
    fn parse_get_nodes_empty() {
        let payload = br#"{"success": true, "message": "", "result": []}"#;
        let nodes = parse_get_nodes_response(payload).unwrap();
        assert!(nodes.is_empty());
    }
}
