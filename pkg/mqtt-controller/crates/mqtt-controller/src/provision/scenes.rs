//! Phase 3: scene reconciliation. For each room, re-issue `scene_add`
//! for every declared scene on every run.
//!
//! We cannot dedup safely: z2m's `bridge/groups` only reports each scene's
//! `id` and `name`, not its brightness/color_temp/state/transition. Any
//! drift in those fields would be invisible, so a stored scene with the
//! same (id, name) but different values would keep playing back the old
//! brightness forever. Reissuing every scene is cheap (a handful per
//! group) and runs once per provision pass, so we just publish them all.
//!
//! No "delete extra scenes" path — z2m has no clean API for that.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::config::Config;

use super::client::{ExistingGroup, Z2mClient};
use super::{ProvisionError, ProvisionOptions, ReconcileSummary};

/// How long to watch `bridge/logging` after each `scene_add` before
/// declaring it delivered. Doubles as pacing: every publish makes z2m
/// emit ~2 groupcasts (scenes.remove + enhancedAdd), and the Zigbee
/// broadcast budget is ~15 in-flight per 9 s network-wide — so one op
/// per 1.5 s stays inside it even with mesh-relayed broadcasts around.
/// (At the old 400 ms settle the coordinator's tx path saturated:
/// ember rejects with `status=BUSY`, zstack with `BUFFER_FULL`, and the
/// dropped scene writes left bulbs recalling stale or missing scenes.)
const SCENE_VERIFY_WINDOW: Duration = Duration::from_millis(1500);

/// Attempts per scene before the pass is declared failed.
const SCENE_MAX_ATTEMPTS: u32 = 4;

/// Base backoff after a failed attempt; grows linearly (8 s, 16 s, 24 s)
/// so a saturated broadcast table (~9 s entry lifetime) fully drains.
const SCENE_RETRY_BACKOFF: Duration = Duration::from_secs(8);

pub async fn reconcile_scenes(
    client: &Z2mClient,
    config: &Config,
    existing: &[ExistingGroup],
    options: &ProvisionOptions,
) -> Result<ReconcileSummary, ProvisionError> {
    let by_name: HashMap<&str, &ExistingGroup> = existing
        .iter()
        .map(|g| (g.friendly_name.as_str(), g))
        .collect();
    let mut summary = ReconcileSummary::default();
    let mut missing_groups: Vec<String> = Vec::new();

    for room in &config.rooms {
        if room.scenes.scenes.is_empty() {
            continue;
        }
        let Some(existing_group) = by_name.get(room.group_name.as_str()) else {
            missing_groups.push(room.group_name.clone());
            continue;
        };

        let existing_ids: std::collections::HashSet<u8> =
            existing_group.scenes.iter().map(|s| s.id).collect();

        for scene in &room.scenes.scenes {
            let reason = if existing_ids.contains(&scene.id) {
                "rewrite (existing id)"
            } else {
                "create (missing)"
            };
            let verb = if options.dry_run {
                "[dry-run] would publish"
            } else {
                "publish"
            };
            tracing::info!(
                group = %room.group_name,
                id = scene.id,
                name = %scene.name,
                reason,
                brightness = ?scene.brightness,
                color_temp = ?scene.color_temp,
                "{verb} scene"
            );
            if !options.dry_run {
                let mut delivered = false;
                for attempt in 1..=SCENE_MAX_ATTEMPTS {
                    let mark = Instant::now();
                    client.add_scene(&room.group_name, scene).await?;
                    tokio::time::sleep(options.settle.max(SCENE_VERIFY_WINDOW)).await;
                    let errors = client
                        .scene_add_errors_since(mark, &room.group_name)
                        .await;
                    if errors.is_empty() {
                        delivered = true;
                        break;
                    }
                    tracing::warn!(
                        group = %room.group_name,
                        id = scene.id,
                        attempt,
                        error = %errors.join(" | "),
                        "scene_add rejected by coordinator; backing off and retrying"
                    );
                    if attempt < SCENE_MAX_ATTEMPTS {
                        tokio::time::sleep(SCENE_RETRY_BACKOFF * attempt).await;
                    }
                }
                if !delivered {
                    return Err(ProvisionError::Invariant(format!(
                        "scene_add for group '{}' scene {} kept failing after {} attempts \
                         (coordinator tx rejections; see zigbee2mqtt log)",
                        room.group_name, scene.id, SCENE_MAX_ATTEMPTS
                    )));
                }
                summary.touched += 1;
            }
        }
    }

    if !missing_groups.is_empty() {
        return Err(ProvisionError::Invariant(format!(
            "these groups are not present in zigbee2mqtt: {missing_groups:?}"
        )));
    }

    Ok(summary)
}
