//! Phase 2: groups + members. Mirrors the `reconcile_groups` function in
//! `pkg/hue-setup/hue_setup.py` step-for-step:
//!
//!   1. Rename groups whose declared id is already in z2m but whose
//!      friendly_name has drifted.
//!   2. (Optional) prune groups not in the config.
//!   3. Create missing groups.
//!   4. Reconcile member sets (additive by default; --prune removes extras).

use std::collections::{HashMap, HashSet};

use crate::config::Config;

use super::client::{ExistingGroup, Z2mClient};
use super::{ProvisionError, ProvisionOptions, ReconcileSummary};

/// Returns `(summary, state_changed)`. `state_changed` signals to the
/// caller that it should re-fetch groups before the scene phase.
pub async fn reconcile_groups(
    client: &Z2mClient,
    config: &Config,
    mut existing: Vec<ExistingGroup>,
    options: &ProvisionOptions,
) -> Result<(ReconcileSummary, bool), ProvisionError> {
    let mut summary = ReconcileSummary::default();
    let mut state_changed = false;

    // The desired set of group friendly_names. We use the room's
    // `group_name` field as the canonical desired name.
    let desired_names: HashSet<String> = config
        .rooms
        .iter()
        .map(|r| r.group_name.clone())
        .collect();

    // ----- Phase 2a: rename groups whose id matches but name drifted ---
    let by_id: HashMap<u8, &ExistingGroup> = existing.iter().map(|g| (g.id, g)).collect();
    let by_name: HashMap<String, &ExistingGroup> = existing
        .iter()
        .map(|g| (g.friendly_name.clone(), g))
        .collect();
    let mut rename_plan: Vec<(String, String)> = Vec::new();
    for room in &config.rooms {
        let Some(existing_by_id) = by_id.get(&room.id) else {
            continue;
        };
        if existing_by_id.friendly_name == room.group_name {
            continue;
        }
        // Collision: another group already owns the target name.
        if let Some(collision) = by_name.get(&room.group_name)
            && collision.id != room.id
        {
            return Err(ProvisionError::Invariant(format!(
                "cannot rename group id={} from {:?} to {:?}: name already used \
                 by group id={}. Resolve manually.",
                room.id, existing_by_id.friendly_name, room.group_name, collision.id
            )));
        }
        rename_plan.push((
            existing_by_id.friendly_name.clone(),
            room.group_name.clone(),
        ));
    }
    drop(by_id);
    drop(by_name);

    for (current_name, new_name) in &rename_plan {
        let verb = if options.dry_run {
            "[dry-run] would rename"
        } else {
            "rename"
        };
        tracing::info!(from = %current_name, to = %new_name, "{verb} group");
        if !options.dry_run {
            client.rename_group(current_name, new_name).await?;
            tokio::time::sleep(options.settle).await;
            summary.touched += 1;
            state_changed = true;
        }
    }

    if !rename_plan.is_empty() {
        if !options.dry_run {
            tokio::time::sleep(options.settle).await;
            existing = client.fetch_groups_fresh().await?;
        } else {
            // In dry-run, patch the in-memory snapshot so subsequent
            // phases don't print misleading messages.
            let renames: HashMap<String, String> =
                rename_plan.iter().cloned().collect();
            for g in &mut existing {
                if let Some(new) = renames.get(&g.friendly_name) {
                    g.friendly_name = new.clone();
                }
            }
        }
    }

    // ----- Phase 2b: prune ---------------------------------------------
    if options.prune {
        let stale: Vec<&ExistingGroup> = existing
            .iter()
            .filter(|g| !desired_names.contains(&g.friendly_name))
            .collect();
        for g in &stale {
            let verb = if options.dry_run {
                "[dry-run] would remove"
            } else {
                "remove"
            };
            tracing::info!(name = %g.friendly_name, id = g.id, "{verb} group: not in config");
            if !options.dry_run {
                client.remove_group(&g.friendly_name, true).await?;
                tokio::time::sleep(options.settle).await;
                summary.touched += 1;
                state_changed = true;
            }
        }
        if state_changed && !options.dry_run {
            tokio::time::sleep(options.settle).await;
            existing = client.fetch_groups_fresh().await?;
        }
    }

    // ----- Phase 2c: create missing groups -----------------------------
    let mut by_name: HashMap<String, ExistingGroup> = existing
        .iter()
        .cloned()
        .map(|g| (g.friendly_name.clone(), g))
        .collect();
    for room in &config.rooms {
        if by_name.contains_key(&room.group_name) {
            tracing::info!(name = %room.group_name, "[skip] group: already exists");
            summary.skipped += 1;
            continue;
        }
        let verb = if options.dry_run {
            "[dry-run] would create"
        } else {
            "create"
        };
        tracing::info!(name = %room.group_name, id = room.id, "{verb} group");
        if !options.dry_run {
            client.add_group(&room.group_name, room.id).await?;
            tokio::time::sleep(options.settle).await;
            summary.touched += 1;
            state_changed = true;
        }
    }

    if state_changed && !options.dry_run {
        tokio::time::sleep(options.settle).await;
        existing = client.fetch_groups().await?;
        by_name = existing
            .iter()
            .cloned()
            .map(|g| (g.friendly_name.clone(), g))
            .collect();
    }

    // ----- Phase 2d: reconcile member sets ----------------------------
    for room in &config.rooms {
        if room.members.is_empty() && !options.prune {
            continue;
        }
        let Some(existing_group) = by_name.get(&room.group_name) else {
            if options.dry_run {
                tracing::info!(
                    name = %room.group_name,
                    "[dry-run] skipping member diff (group would be created first)"
                );
            }
            continue;
        };

        // Member keys live in the config as "<friendly_name>/<endpoint>".
        // z2m's bridge/groups always returns ieee_address; normalize
        // both sides through the canonical mapping so the diff matches.
        let normalize = |s: &str| normalize_member_key(s, &config.name_by_address);
        let desired: HashSet<String> = room.members.iter().map(|m| normalize(m)).collect();
        let current: HashSet<String> = existing_group
            .members
            .iter()
            .map(|m| normalize(&m.as_key()))
            .collect();

        let missing: Vec<String> = desired.difference(&current).cloned().collect();
        let extra: Vec<String> = current.difference(&desired).cloned().collect();

        for member in &missing {
            let Some((device, endpoint)) = parse_member_key(member) else {
                return Err(ProvisionError::Invariant(format!(
                    "malformed member {member:?} in room {:?}",
                    room.name
                )));
            };
            let verb = if options.dry_run {
                "[dry-run] would add"
            } else {
                "add"
            };
            tracing::info!(member = %member, group = %room.group_name, "{verb} member to group");
            if !options.dry_run {
                client.add_member(&room.group_name, &device, endpoint).await?;
                tokio::time::sleep(options.settle).await;
                summary.touched += 1;
                state_changed = true;
            }
        }

        if options.prune {
            for member in &extra {
                let Some((device, endpoint)) = parse_member_key(member) else {
                    continue;
                };
                let verb = if options.dry_run {
                    "[dry-run] would remove"
                } else {
                    "remove"
                };
                tracing::info!(
                    member = %member,
                    group = %room.group_name,
                    "{verb} member from group"
                );
                if !options.dry_run {
                    client.remove_member(&room.group_name, &device, endpoint).await?;
                    tokio::time::sleep(options.settle).await;
                    summary.touched += 1;
                    state_changed = true;
                }
            }
        } else {
            for member in &extra {
                tracing::info!(
                    member = %member,
                    group = %room.group_name,
                    "[skip] member is in z2m but not in config (re-run with --prune to remove)"
                );
                summary.skipped += 1;
            }
        }
    }

    Ok((summary, state_changed))
}

/// Translate any `0x...` device part of a member key to its canonical
/// friendly name. Mirrors `normalize_member_key` in hue_setup.py.
fn normalize_member_key(member: &str, name_by_address: &std::collections::BTreeMap<String, String>) -> String {
    let Some((device, endpoint)) = member.rsplit_once('/') else {
        return member.to_string();
    };
    if device.starts_with("0x")
        && let Some(name) = name_by_address.get(device)
    {
        return format!("{name}/{endpoint}");
    }
    member.to_string()
}

fn parse_member_key(member: &str) -> Option<(String, u32)> {
    let (device, endpoint) = member.rsplit_once('/')?;
    let endpoint = endpoint.parse::<u32>().ok()?;
    Some((device.to_string(), endpoint))
}
