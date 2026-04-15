//! Phase 4: per-device option writes. For each device in the catalog
//! that has a non-empty `options` map, dedup-check each option against
//! the device's cached state and write any that differ. Same dedup
//! semantics as the python `reconcile_devices`.

use std::collections::HashMap;

use serde_json::Value;

use crate::config::Config;

use super::client::Z2mClient;
use super::{ProvisionError, ProvisionOptions, ReconcileSummary};

pub async fn reconcile_devices(
    client: &Z2mClient,
    config: &Config,
    state_cache: &HashMap<String, Value>,
    options: &ProvisionOptions,
) -> Result<ReconcileSummary, ProvisionError> {
    let mut summary = ReconcileSummary::default();

    for (friendly_name, entry) in &config.devices {
        let opts = entry.options();
        if opts.is_empty() {
            continue;
        }
        // Z-Wave plugs are not managed by zigbee2mqtt — their options
        // (if any) must be set via the Z-Wave JS UI API, not z2m /set.
        if entry.is_zwave_plug() {
            continue;
        }

        let existing_state = state_cache.get(friendly_name);
        if existing_state.is_none() {
            tracing::warn!(
                device = friendly_name,
                "device not in WebSocket state cache; writing options unconditionally"
            );
        }
        let existing_obj = existing_state.and_then(|s| s.as_object());

        for (opt_key, opt_value) in opts {
            let current = existing_obj.and_then(|o| o.get(opt_key));
            if current == Some(opt_value) {
                tracing::info!(
                    device = %friendly_name,
                    key = %opt_key,
                    "[skip] option: already at desired value"
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
                key = %opt_key,
                value = %opt_value,
                was = ?current,
                "{verb} option"
            );
            if !options.dry_run {
                let body = Value::Object(
                    [(opt_key.clone(), opt_value.clone())]
                        .into_iter()
                        .collect(),
                );
                client.set_device_options(friendly_name, &body).await?;
                tokio::time::sleep(options.settle).await;
                summary.touched += 1;
            }
        }
    }

    Ok(summary)
}
