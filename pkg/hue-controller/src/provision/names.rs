//! Phase 1: device renames. Walk `name_by_address` and rename any z2m
//! device whose current friendly_name doesn't match the desired one.
//! Issued with `homeassistant_rename: true` so HA's entity ids follow.

use std::collections::HashMap;

use crate::config::Config;

use super::client::{ExistingDevice, Z2mClient};
use super::{ProvisionError, ProvisionOptions, ReconcileSummary};

pub async fn reconcile_names(
    client: &Z2mClient,
    config: &Config,
    existing: &[ExistingDevice],
    options: &ProvisionOptions,
) -> Result<ReconcileSummary, ProvisionError> {
    if config.name_by_address.is_empty() {
        return Ok(ReconcileSummary::default());
    }

    let by_address: HashMap<&str, &ExistingDevice> = existing
        .iter()
        .map(|d| (d.ieee_address.as_str(), d))
        .collect();
    let mut summary = ReconcileSummary::default();

    for (ieee, desired_name) in &config.name_by_address {
        let Some(found) = by_address.get(ieee.as_str()) else {
            tracing::warn!(
                ieee = %ieee,
                desired = %desired_name,
                "rename: device not present in z2m bridge/devices (offline or not paired); skipping"
            );
            continue;
        };
        if found.friendly_name == *desired_name {
            tracing::info!(ieee = %ieee, name = %desired_name, "[skip] already named");
            summary.skipped += 1;
            continue;
        }
        let verb = if options.dry_run {
            "[dry-run] would rename"
        } else {
            "rename"
        };
        tracing::info!(
            ieee = %ieee,
            from = %found.friendly_name,
            to = %desired_name,
            "{verb}"
        );
        if !options.dry_run {
            client.rename_device(ieee, desired_name).await?;
            tokio::time::sleep(options.settle).await;
            summary.touched += 1;
        }
    }

    Ok(summary)
}
