//! Phase 1: device renames. Walk `name_by_address` and rename any z2m
//! device whose current friendly_name doesn't match the desired one.
//! Issued with `homeassistant_rename: true` so HA's entity ids follow.
//!
//! When two (or more) devices need to swap names (A→B while B→A), a
//! naive sequential rename fails because the target name is still taken.
//! We detect these conflicts and route through a temporary intermediate
//! name (`__tmp_swap_<ieee>`) before assigning the final name.

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

    // Build the rename plan: (ieee, current_name, desired_name) for
    // devices that need renaming.
    let mut plan: Vec<(&str, String, &str)> = Vec::new();
    for (ieee, desired_name) in &config.name_by_address {
        // Z-Wave devices are managed by Z-Wave JS UI, not z2m.
        if ieee.starts_with("zwave:") {
            continue;
        }
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
        plan.push((ieee.as_str(), found.friendly_name.clone(), desired_name.as_str()));
    }

    // Collect names currently in use by devices that need renaming.
    // A rename A→X is blocked when X is the *current* name of another
    // device in the plan (that device hasn't been renamed yet).
    let current_names: HashMap<&str, &str> = plan
        .iter()
        .map(|(ieee, current, _)| (current.as_str(), *ieee))
        .collect();

    // Phase 1: rename blocked devices to temporaries first.
    // A device is "blocked" when its desired name is currently held by
    // another device that also needs renaming.
    let mut tmp_renamed: Vec<(&str, String)> = Vec::new(); // (ieee, tmp_name)
    for &(ieee, _, desired) in &plan {
        if let Some(&holder_ieee) = current_names.get(desired) {
            if holder_ieee != ieee {
                // The desired name is held by another device. Rename
                // that device to a temporary first.
                let tmp_name = format!("__tmp_swap_{holder_ieee}");
                // Only add to tmp_renamed if we haven't already queued
                // a temp rename for this holder.
                if !tmp_renamed.iter().any(|(i, _)| *i == holder_ieee) {
                    tracing::info!(
                        ieee = %holder_ieee,
                        from = %desired,
                        to = %tmp_name,
                        "rename to temporary (swap conflict)"
                    );
                    if !options.dry_run {
                        client.rename_device(holder_ieee, &tmp_name).await?;
                        tokio::time::sleep(options.settle).await;
                        summary.touched += 1;
                    }
                    tmp_renamed.push((holder_ieee, tmp_name));
                }
            }
        }
    }

    // Phase 2: apply all final renames.
    for &(ieee, ref _current, desired) in &plan {
        let verb = if options.dry_run {
            "[dry-run] would rename"
        } else {
            "rename"
        };
        let actual_current = tmp_renamed
            .iter()
            .find(|(i, _)| *i == ieee)
            .map(|(_, tmp)| tmp.as_str())
            .unwrap_or(_current.as_str());
        tracing::info!(
            ieee = %ieee,
            from = %actual_current,
            to = %desired,
            "{verb}"
        );
        if !options.dry_run {
            client.rename_device(ieee, desired).await?;
            tokio::time::sleep(options.settle).await;
            summary.touched += 1;
        }
    }

    Ok(summary)
}
