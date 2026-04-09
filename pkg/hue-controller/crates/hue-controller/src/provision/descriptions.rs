//! Phase 1b: device descriptions. Walk the catalog and reconcile each
//! device's zigbee2mqtt description against the desired value from
//! the Nix config. Uses `bridge/request/device/options` to set the
//! `description` field in z2m's device configuration.
//!
//! Only devices with an explicit `description` in the catalog are
//! touched — same additive semantics as the options phase.

use std::collections::HashMap;

use crate::config::Config;

use super::client::{ExistingDevice, Z2mClient};
use super::{ProvisionError, ProvisionOptions, ReconcileSummary};

pub async fn reconcile_descriptions(
    client: &Z2mClient,
    config: &Config,
    existing: &[ExistingDevice],
    options: &ProvisionOptions,
) -> Result<ReconcileSummary, ProvisionError> {
    let by_ieee: HashMap<&str, &ExistingDevice> = existing
        .iter()
        .map(|d| (d.ieee_address.as_str(), d))
        .collect();
    let mut summary = ReconcileSummary::default();

    for (friendly_name, entry) in &config.devices {
        let Some(desired) = entry.description() else {
            continue;
        };

        let ieee = entry.ieee_address();
        let Some(found) = by_ieee.get(ieee.as_str()) else {
            tracing::warn!(
                ieee = %ieee,
                name = %friendly_name,
                "description: device not in z2m (offline or not paired); skipping"
            );
            continue;
        };

        if found.description == desired {
            tracing::info!(
                device = %friendly_name,
                "[skip] description: already matches"
            );
            summary.skipped += 1;
            continue;
        }

        let verb = if options.dry_run {
            "[dry-run] would set"
        } else {
            "set"
        };
        tracing::info!(
            device = %friendly_name,
            from = %found.description,
            to = %desired,
            "{verb} description"
        );
        if !options.dry_run {
            client
                .set_device_bridge_options(
                    ieee,
                    &serde_json::json!({ "description": desired }),
                )
                .await?;
            tokio::time::sleep(options.settle).await;
            summary.touched += 1;
        }
    }

    Ok(summary)
}
