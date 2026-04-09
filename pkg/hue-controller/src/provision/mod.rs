//! Provisioning subcommand. Reconciles z2m groups, members, scenes, and
//! per-device options against the JSON config — same five-phase shape
//! as `pkg/hue-setup/hue_setup.py`, just in Rust.
//!
//! Phases (in order):
//!
//!   1. **Names.** Walk `name_by_address` and rename any z2m device whose
//!      current `friendly_name` doesn't match the desired one. Issued
//!      with `homeassistant_rename: true` so HA's entity ids follow.
//!      Runs FIRST so all subsequent phases see the corrected names.
//!
//!   1b. **Descriptions.** Reconcile each device's z2m description against
//!       the Nix config. Uses `bridge/request/device/options` to set
//!       the `description` field. Only devices with an explicit
//!       `description` in the catalog are touched.
//!
//!   2. **Groups.** Rename groups whose id is already in z2m but whose
//!      friendly_name has drifted. Then (optionally) prune groups not in
//!      the config. Then create missing groups. Then reconcile member
//!      sets (additive by default; --prune removes extras).
//!
//!   3. **Scenes.** For each room, ensure every declared scene exists in
//!      z2m. Dedup by id+name; --force-update re-issues every scene.
//!
//!   4. **Devices.** Per-device options writes (motion sensor sensitivity,
//!      led indication, occupancy timeout). Each option is dedup-checked
//!      against the device's retained state before writing — re-runs are
//!      no-ops once everything is in sync.
//!
//! All phases share the same [`Z2mClient`] for MQTT request/response
//! correlation via transaction ids; that piece lives in [`client`].
//!
//! Provisioning is intentionally separate from the daemon's runtime MQTT
//! loop. The two never share an MQTT connection — provisioning runs as a
//! systemd `oneShot` before the daemon starts. Conceptually they're two
//! separate programs that happen to live in one binary for deployment
//! convenience.

pub mod client;
mod descriptions;
mod devices;
mod groups;
mod names;
mod scenes;

use std::time::Duration;

use anyhow::Context;
use thiserror::Error;

use crate::config::Config;
use crate::mqtt::MqttConfig;

pub use client::Z2mClient;

/// Knobs that control how aggressive provisioning is.
#[derive(Debug, Clone, Copy)]
pub struct ProvisionOptions {
    /// Don't actually publish anything; just log what *would* happen.
    pub dry_run: bool,

    /// Re-issue `scene_add` for every configured scene even if a scene
    /// with the same id and name already exists.
    pub force_update: bool,

    /// Remove members and groups present in z2m but not in the config.
    /// Default is additive-only.
    pub prune: bool,

    /// Per-call MQTT timeout (request → response).
    pub timeout: Duration,

    /// How long to wait between successive z2m mutations so the bridge
    /// has time to settle (re-publish bridge/groups, etc).
    pub settle: Duration,

    /// How many times to retry the initial bridge/groups + bridge/devices
    /// fetch on early-boot races.
    pub fetch_attempts: u32,

    /// Delay between fetch retries.
    pub fetch_retry: Duration,
}

impl Default for ProvisionOptions {
    fn default() -> Self {
        Self {
            dry_run: false,
            force_update: false,
            prune: false,
            timeout: Duration::from_secs(5),
            settle: Duration::from_millis(400),
            fetch_attempts: 12,
            fetch_retry: Duration::from_secs(5),
        }
    }
}

#[derive(Debug, Error)]
pub enum ProvisionError {
    #[error("mqtt error: {0}")]
    Mqtt(#[from] crate::mqtt::MqttError),

    #[error("z2m client error: {0}")]
    Client(#[from] client::Z2mClientError),

    #[error("config invariant violated: {0}")]
    Invariant(String),
}

/// Reconcile counters returned for logging.
#[derive(Debug, Default, Clone, Copy)]
pub struct ReconcileSummary {
    pub touched: u32,
    pub skipped: u32,
}

impl std::ops::AddAssign for ReconcileSummary {
    fn add_assign(&mut self, rhs: Self) {
        self.touched += rhs.touched;
        self.skipped += rhs.skipped;
    }
}

/// Run the full reconciliation. Same flow as the Python `reconcile()`.
pub async fn reconcile(
    config: &Config,
    mqtt: MqttConfig,
    options: ProvisionOptions,
) -> anyhow::Result<ReconcileSummary> {
    let client = Z2mClient::connect(mqtt, options.timeout)
        .await
        .context("connecting to mqtt for provisioning")?;

    let mut summary = ReconcileSummary::default();

    // Fetch the device inventory once — used by both the names phase
    // and the descriptions phase.
    let existing_devices = retry_fetch(
        "fetch zigbee2mqtt/bridge/devices",
        options.fetch_attempts,
        options.fetch_retry,
        || client.fetch_devices(),
    )
    .await?;

    // Phase 1: device renames (only if name_by_address is non-empty).
    if !config.name_by_address.is_empty() {
        let s = names::reconcile_names(&client, config, &existing_devices, &options).await?;
        summary += s;
        if s.touched > 0 && !options.dry_run {
            tokio::time::sleep(options.settle).await;
        }
    }

    // Phase 1b: device descriptions.
    {
        let s =
            descriptions::reconcile_descriptions(&client, config, &existing_devices, &options)
                .await?;
        summary += s;
        if s.touched > 0 && !options.dry_run {
            tokio::time::sleep(options.settle).await;
        }
    }

    // Phase 2: groups + members.
    let existing_groups = retry_fetch(
        "fetch zigbee2mqtt/bridge/groups",
        options.fetch_attempts,
        options.fetch_retry,
        || client.fetch_groups(),
    )
    .await?;
    let (group_summary, state_changed) =
        groups::reconcile_groups(&client, config, existing_groups, &options).await?;
    summary += group_summary;

    // Re-fetch groups for the scene phase. After a mutation we need
    // fresh delivery (the cache still holds the pre-mutation copy);
    // otherwise the cached payload is fine.
    let existing_groups_for_scenes = if state_changed && !options.dry_run {
        tokio::time::sleep(options.settle).await;
        client.fetch_groups_fresh().await?
    } else {
        client.fetch_groups().await?
    };

    // Phase 3: scenes.
    let scene_summary =
        scenes::reconcile_scenes(&client, config, &existing_groups_for_scenes, &options).await?;
    summary += scene_summary;

    // Phase 4: per-device options.
    let device_summary = devices::reconcile_devices(&client, config, &options).await?;
    summary += device_summary;

    client.shutdown().await;
    Ok(summary)
}

/// Retry wrapper used for the inventory fetches that race z2m's startup.
/// Mirrors the Python `_fetch_with_retry`.
async fn retry_fetch<T, F, Fut>(
    label: &str,
    attempts: u32,
    delay: Duration,
    mut f: F,
) -> Result<T, ProvisionError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<T, client::Z2mClientError>>,
{
    let mut last_err: Option<client::Z2mClientError> = None;
    for attempt in 1..=attempts {
        match f().await {
            Ok(v) => return Ok(v),
            Err(e) => {
                tracing::info!(
                    attempt,
                    attempts,
                    error = %e,
                    "{label} failed; retrying in {:.1}s",
                    delay.as_secs_f64()
                );
                last_err = Some(e);
                tokio::time::sleep(delay).await;
            }
        }
    }
    Err(last_err
        .map(ProvisionError::Client)
        .unwrap_or_else(|| ProvisionError::Invariant(format!("{label} retry loop ended without an error"))))
}
