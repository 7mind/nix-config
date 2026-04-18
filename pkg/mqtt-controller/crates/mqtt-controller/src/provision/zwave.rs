//! Z-Wave provisioning phase: rename Z-Wave nodes to match the desired
//! names from the device catalog.
//!
//! Transport logic (connect, API request/response pairs, get_nodes,
//! setNodeName, setNodeLocation) lives in [`crate::mqtt::zwave_api`] —
//! the daemon's startup seed path uses the same client.

use std::collections::BTreeMap;

use crate::config::Config;
use crate::mqtt::zwave_api::{ZwaveApiClient, ZwaveNode};
use crate::mqtt::MqttConfig;

use super::{ProvisionOptions, ReconcileSummary};

/// Reconcile Z-Wave plug names and locations against the device catalog.
///
/// For each Z-Wave plug in the catalog (protocol == zwave):
///   - Check if the node's current name matches the desired name and
///     rename if it doesn't (via `setNodeName`).
///   - If the device has a `description`, check if the node's current
///     location matches and set it if it doesn't (via `setNodeLocation`).
///     This maps the Nix-side `description` field to Z-Wave's location
///     concept (z2m uses `bridge/request/device/options` for Zigbee
///     descriptions, but Z-Wave uses a separate API).
pub async fn reconcile_zwave_names(
    config: &Config,
    mqtt_config: &MqttConfig,
    options: &ProvisionOptions,
) -> anyhow::Result<ReconcileSummary> {
    struct Desired<'a> {
        name: &'a str,
        location: Option<&'a str>,
    }
    let mut desired: BTreeMap<u16, Desired<'_>> = BTreeMap::new();
    for (name, entry) in &config.devices {
        if let Some(node_id) = entry.zwave_node_id() {
            desired.insert(node_id, Desired {
                name: name.as_str(),
                location: entry.description(),
            });
        }
    }

    if desired.is_empty() {
        return Ok(ReconcileSummary::default());
    }

    tracing::info!(
        zwave_plugs = desired.len(),
        "zwave: checking node names and locations"
    );

    let mut client = ZwaveApiClient::connect(mqtt_config, options.timeout).await?;
    let nodes = client.get_nodes(options.timeout).await?;
    let nodes_by_id: BTreeMap<u16, ZwaveNode> =
        nodes.into_iter().map(|n| (n.node_id, n)).collect();

    let mut summary = ReconcileSummary::default();

    for (&node_id, desired) in &desired {
        let Some(node) = nodes_by_id.get(&node_id) else {
            tracing::warn!(
                node_id,
                desired = desired.name,
                "zwave: node not found (offline or not paired); skipping"
            );
            continue;
        };

        if node.current_name == desired.name {
            tracing::info!(
                node_id,
                name = desired.name,
                "[skip] name already matches"
            );
            summary.skipped += 1;
        } else {
            let verb = if options.dry_run { "[dry-run] would rename" } else { "rename" };
            tracing::info!(
                node_id,
                from = %node.current_name,
                to = desired.name,
                "zwave: {verb}"
            );
            if !options.dry_run {
                client.set_node_name(node_id, desired.name, options.timeout).await?;
                tokio::time::sleep(options.settle * 2).await;
                summary.touched += 1;
            }
        }

        if let Some(desired_loc) = desired.location {
            if node.current_location == desired_loc {
                tracing::info!(
                    node_id,
                    location = desired_loc,
                    "[skip] location already matches"
                );
                summary.skipped += 1;
            } else {
                let verb = if options.dry_run { "[dry-run] would set" } else { "set" };
                tracing::info!(
                    node_id,
                    from = %node.current_location,
                    to = desired_loc,
                    "zwave: {verb} location"
                );
                if !options.dry_run {
                    client.set_node_location(node_id, desired_loc, options.timeout).await?;
                    tokio::time::sleep(options.settle * 2).await;
                    summary.touched += 1;
                }
            }
        }
    }

    client.disconnect().await;
    Ok(summary)
}
