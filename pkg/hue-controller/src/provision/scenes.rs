//! Phase 3: scene reconciliation. For each room, walk every declared
//! scene; if z2m doesn't already have one with that id+name, issue a
//! `scene_add`. With `--force-update`, re-issue every declared scene
//! regardless of whether it already exists.
//!
//! No "delete extra scenes" path — z2m has no clean API for that and
//! the python version doesn't do it either.

use std::collections::HashMap;

use crate::config::Config;

use super::client::{ExistingGroup, ExistingScene, Z2mClient};
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

        let existing_by_id: HashMap<u8, &ExistingScene> = existing_group
            .scenes
            .iter()
            .map(|s| (s.id, s))
            .collect();

        for scene in &room.scenes.scenes {
            let current = existing_by_id.get(&scene.id).copied();
            let (needs, reason) = scene_status(scene, current, options.force_update);
            if !needs {
                tracing::info!(
                    group = %room.group_name,
                    id = scene.id,
                    name = %scene.name,
                    "[skip] scene: {reason}"
                );
                summary.skipped += 1;
                continue;
            }
            let verb = if options.dry_run {
                "[dry-run] would create"
            } else {
                "create"
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

fn scene_status(
    desired: &crate::config::Scene,
    existing: Option<&ExistingScene>,
    force_update: bool,
) -> (bool, &'static str) {
    match existing {
        None => (true, "missing"),
        Some(e) if e.name != desired.name => (true, "name differs"),
        Some(_) if force_update => (true, "force-update"),
        Some(_) => (false, "already exists with matching id+name"),
    }
}
