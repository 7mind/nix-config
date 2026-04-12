//! Phase 4: per-device option writes. For each device in the catalog
//! that has a non-empty `options` map, dedup-check each option against
//! the device's retained state and write any that differ. Same dedup
//! semantics as the python `reconcile_devices`.

use serde_json::Value;

use crate::config::{Config, DeviceCatalogEntry};

use super::client::Z2mClient;
use super::{ProvisionError, ProvisionOptions, ReconcileSummary};

pub async fn reconcile_devices(
    client: &Z2mClient,
    config: &Config,
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

        let existing_state = client.fetch_device_state(friendly_name).await?;
        if existing_state.is_none() {
            tracing::info!(
                device = %friendly_name,
                "[warn] no retained state available; will write all options unconditionally"
            );
        }
        let existing_obj = existing_state
            .as_ref()
            .and_then(|v| v.as_object());

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
