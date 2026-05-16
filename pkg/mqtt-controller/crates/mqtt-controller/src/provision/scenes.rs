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

use crate::config::Config;

use super::client::{ExistingGroup, Z2mClient};
use super::{ProvisionError, ProvisionOptions, ReconcileSummary};

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
                client.add_scene(&room.group_name, scene).await?;
                tokio::time::sleep(options.settle).await;
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
