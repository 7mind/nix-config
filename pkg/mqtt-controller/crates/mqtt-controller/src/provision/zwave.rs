//! Z-Wave provisioning phase: rename Z-Wave nodes to match the desired
//! names from the device catalog.
//!
//! Transport logic (connect, API request/response pairs, get_nodes,
//! setNodeName, setNodeLocation) lives in [`crate::mqtt::zwave_api`] —
//! the daemon's startup seed path uses the same client.

use std::collections::BTreeMap;
use std::time::Duration;

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

    let (mut client, nodes) = fetch_zwave_nodes(mqtt_config, options).await?;
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

/// Connect + getNodes with retries on the start-race errors we see when
/// zwave-js-ui's MQTT gateway is up but the driver is not yet connected.
const ZWAVE_FETCH_ATTEMPTS: u32 = 4;

async fn fetch_zwave_nodes(
    mqtt_config: &MqttConfig,
    options: &ProvisionOptions,
) -> anyhow::Result<(ZwaveApiClient, Vec<ZwaveNode>)> {
    let mut last_err: Option<anyhow::Error> = None;
    for attempt in 1..=ZWAVE_FETCH_ATTEMPTS {
        match try_fetch_zwave_nodes(mqtt_config, options.timeout).await {
            Ok(pair) => return Ok(pair),
            Err(e) if attempt < ZWAVE_FETCH_ATTEMPTS && is_transient_zwave_error(&e) => {
                tracing::warn!(
                    attempt,
                    attempts = ZWAVE_FETCH_ATTEMPTS,
                    error = %e,
                    "zwave inventory fetch failed; retrying"
                );
                last_err = Some(e);
                tokio::time::sleep(options.fetch_retry).await;
            }
            Err(e) => return Err(e),
        }
    }
    Err(last_err.unwrap_or_else(|| anyhow::anyhow!("zwave inventory retry loop ended without an error")))
}

async fn try_fetch_zwave_nodes(
    mqtt_config: &MqttConfig,
    timeout: Duration,
) -> anyhow::Result<(ZwaveApiClient, Vec<ZwaveNode>)> {
    let mut client = ZwaveApiClient::connect(mqtt_config, timeout).await?;
    let nodes = client.get_nodes(timeout).await?;
    Ok((client, nodes))
}

/// Timeout / "Z-Wave client not connected" — the gateway answered or the
/// request raced startup. Other errors (auth, parse) are not retried.
pub(crate) fn is_transient_zwave_error(err: &anyhow::Error) -> bool {
    let full = format!("{err:#}");
    full.contains("timed out") || full.contains("not connected")
}

#[cfg(test)]
mod tests {
    use super::is_transient_zwave_error;

    #[test]
    fn get_nodes_timeout_is_transient() {
        let err = anyhow::anyhow!(
            "zwave: zwave/_CLIENTS/ZWAVE_GATEWAY-zwave/api/getNodes/set API timed out"
        );
        assert!(is_transient_zwave_error(&err));
    }

    #[test]
    fn client_not_connected_is_transient() {
        let err = anyhow::anyhow!("zwave: getNodes API failed: Z-Wave client not connected");
        assert!(is_transient_zwave_error(&err));
    }

    #[test]
    fn connect_timeout_is_transient() {
        let err = anyhow::anyhow!("zwave mqtt connect timed out");
        assert!(is_transient_zwave_error(&err));
    }

    #[test]
    fn parse_failure_is_not_transient() {
        let err = anyhow::anyhow!("zwave: getNodes response missing 'result' array");
        assert!(!is_transient_zwave_error(&err));
    }
}
