//! Z-Wave provisioning phase: rename Z-Wave nodes to match the desired
//! names from the device catalog.
//!
//! Z-Wave JS UI exposes node rename via its MQTT gateway API:
//!   - Discover current node names by subscribing to `zwave/+/nodeinfo`
//!     and reading the retained `{"id":N,"name":"..."}` payloads.
//!   - Rename via `zwave/_CLIENTS/ZWAVE_GATEWAY-zwave/api/setNodeName/set`
//!     with payload `{"args":[nodeId,"newName"]}`.
//!
//! Unlike zigbee2mqtt, Z-Wave JS UI doesn't use transaction IDs for
//! request/response correlation. We use a simple publish-and-wait pattern
//! with a per-operation timeout.

use std::collections::BTreeMap;
use std::time::Duration;

use rumqttc::{AsyncClient, MqttOptions, QoS};

use crate::config::Config;
use crate::mqtt::MqttConfig;
use crate::mqtt::topics;

use super::{ProvisionOptions, ReconcileSummary};

/// Discovered Z-Wave node from `zwave/<name>/nodeinfo`.
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

    // Connect to MQTT and discover current node names.
    let mut opts = MqttOptions::new(
        format!("hue-controller-zwave-provision-{}", uuid::Uuid::new_v4()),
        &mqtt_config.host,
        mqtt_config.port,
    );
    opts.set_credentials(&mqtt_config.user, &mqtt_config.password);
    opts.set_keep_alive(mqtt_config.keep_alive);
    opts.set_inflight(20);
    opts.set_max_packet_size(2 * 1024 * 1024, 2 * 1024 * 1024);

    let (client, mut eventloop) = AsyncClient::new(opts, 100);

    // Wait for CONNACK.
    loop {
        match tokio::time::timeout(options.timeout, eventloop.poll()).await {
            Ok(Ok(rumqttc::Event::Incoming(rumqttc::Packet::ConnAck(_)))) => break,
            Ok(Ok(_)) => continue,
            Ok(Err(e)) => anyhow::bail!("zwave mqtt connect error: {e}"),
            Err(_) => anyhow::bail!("zwave mqtt connect timed out"),
        }
    }

    // Subscribe to nodeinfo for all nodes.
    client
        .subscribe(topics::zwave_nodeinfo_wildcard(), QoS::AtLeastOnce)
        .await?;

    // Poll until we receive the SUBACK — only after that will the
    // broker start delivering retained messages.
    let suback_deadline = tokio::time::Instant::now() + options.timeout;
    loop {
        let remaining = suback_deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            anyhow::bail!("zwave: timed out waiting for SUBACK on nodeinfo wildcard");
        }
        match tokio::time::timeout(remaining, eventloop.poll()).await {
            Ok(Ok(rumqttc::Event::Incoming(rumqttc::Packet::SubAck(_)))) => break,
            Ok(Ok(_)) => continue,
            Ok(Err(e)) => anyhow::bail!("zwave mqtt suback error: {e}"),
            Err(_) => anyhow::bail!("zwave: timed out waiting for SUBACK"),
        }
    }

    // Drain retained nodeinfo messages. Retained messages arrive
    // right after the SUBACK; we collect until `desired.len()` nodes
    // are found or the timeout elapses.
    let mut nodes_by_id: BTreeMap<u16, ZwaveNode> = BTreeMap::new();
    let drain_deadline = tokio::time::Instant::now() + options.timeout;

    while nodes_by_id.len() < desired.len() {
        let remaining = drain_deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        match tokio::time::timeout(remaining, eventloop.poll()).await {
            Ok(Ok(rumqttc::Event::Incoming(rumqttc::Packet::Publish(p)))) => {
                if let Some(node) = parse_nodeinfo(&p.payload) {
                    // Only track nodes we care about.
                    if desired.contains_key(&node.node_id) {
                        tracing::info!(
                            node_id = node.node_id,
                            current_name = %node.current_name,
                            "zwave: discovered node"
                        );
                        nodes_by_id.insert(node.node_id, node);
                    }
                }
            }
            Ok(Ok(_)) => continue,
            Ok(Err(e)) => {
                tracing::warn!(error = ?e, "zwave: eventloop error during discovery");
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            Err(_) => break, // timeout
        }
    }

    let mut summary = ReconcileSummary::default();

    for (&node_id, &desired_name) in &desired {
        let Some(node) = nodes_by_id.get(&node_id) else {
            tracing::warn!(
                node_id,
                desired = desired_name,
                "zwave: node not found in discovery (offline or not paired); skipping"
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
            let topic = topics::zwave_api_set_node_name();
            let payload = serde_json::json!({"args": [node_id, desired_name]});
            client
                .publish(
                    &topic,
                    QoS::AtLeastOnce,
                    false,
                    serde_json::to_vec(&payload)?,
                )
                .await?;

            // Wait for the rename to propagate. Z-Wave JS UI re-publishes
            // all topics under the new name after a rename.
            tokio::time::sleep(options.settle * 2).await;
            summary.touched += 1;
        }
    }

    let _ = client.disconnect().await;
    Ok(summary)
}

/// Parse a Z-Wave nodeinfo payload. Returns `None` for non-node or
/// empty-named entries (the `nodeID_N` topics have `"name":""`).
fn parse_nodeinfo(payload: &[u8]) -> Option<ZwaveNode> {
    let value: serde_json::Value = serde_json::from_slice(payload).ok()?;
    let node_id = value.get("id")?.as_u64()? as u16;
    let name = value.get("name")?.as_str()?;
    if name.is_empty() {
        return None;
    }
    Some(ZwaveNode {
        node_id,
        current_name: name.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_nodeinfo_named() {
        let payload = br#"{"id":6,"name":"Plug4","loc":"","ready":true}"#;
        let node = parse_nodeinfo(payload).unwrap();
        assert_eq!(node.node_id, 6);
        assert_eq!(node.current_name, "Plug4");
    }

    #[test]
    fn parse_nodeinfo_empty_name_skipped() {
        let payload = br#"{"id":1,"name":"","loc":"","ready":true}"#;
        assert!(parse_nodeinfo(payload).is_none());
    }

    #[test]
    fn parse_nodeinfo_controller() {
        // The controller node (id=1) typically has no name.
        let payload = br#"{"id":1,"name":"","loc":""}"#;
        assert!(parse_nodeinfo(payload).is_none());
    }
}
