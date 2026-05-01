//! Periodic retention sweep.
//!
//! Two layers run on the same interval:
//!
//!   1. **Time bound** — delete every row older than
//!      `now - retention_days`. ON DELETE CASCADE on the entity index
//!      reclaims its rows automatically.
//!   2. **Per-entity row cap** — for each `entity` in
//!      `decision_log_entity` keep only the `per_entity_max_rows` most
//!      recent rows. Guards against a chatty entity pushing a quiet
//!      entity's history out of the time window.
//!
//! The sweep also runs `PRAGMA incremental_vacuum` after each pass so
//! freed pages return to the OS instead of growing the file
//! monotonically.

use std::time::Duration;

use tokio::task::JoinHandle;
use turso::{Connection, Database};

use super::{AuditConfig, AuditError, apply_pragmas};

const DAY_MS: i64 = 86_400 * 1_000;

const DELETE_OLD_LOGS: &str = "DELETE FROM decision_log WHERE ts_ms < ?";

/// Per-entity trim. Deletes index rows beyond the cap; the orphaned
/// `decision_log` row is later swept by the time-based DELETE if it
/// has no other entity references — we don't try to detect orphans
/// here because the time bound will catch them, and a single
/// orphan-collecting query across the whole table would dominate the
/// sweep cost.
const TRIM_ENTITY_INDEX: &str = "DELETE FROM decision_log_entity \
    WHERE entity = ? AND log_id NOT IN ( \
        SELECT log_id FROM decision_log_entity \
        WHERE entity = ? \
        ORDER BY ts_ms DESC \
        LIMIT ? \
    )";

const LIST_ENTITIES: &str = "SELECT DISTINCT entity FROM decision_log_entity";

/// Spawn the retention sweep task. Returns its `JoinHandle`; abandoning
/// it is safe — the task exits when the runtime shuts down.
pub fn spawn(db: Database, config: AuditConfig) -> JoinHandle<()> {
    tokio::spawn(retention_loop(db, config))
}

async fn retention_loop(db: Database, config: AuditConfig) {
    let conn = match db.connect() {
        Ok(c) => c,
        Err(e) => {
            tracing::error!(error = %e, "audit retention: failed to obtain connection; task exiting");
            return;
        }
    };
    if let Err(e) = apply_pragmas(&conn).await {
        tracing::error!(error = %e, "audit retention: failed to apply pragmas; task exiting");
        return;
    }

    let interval = Duration::from_secs(config.sweep_interval_secs.max(60));
    let mut ticker = tokio::time::interval(interval);
    // The first tick fires immediately; let it. Cleaning up on startup
    // means a daemon restart after a long offline period catches up
    // before serving requests.
    loop {
        ticker.tick().await;
        if let Err(e) = sweep(&conn, &config).await {
            tracing::warn!(error = %e, "audit retention sweep failed");
        }
    }
}

async fn sweep(conn: &Connection, config: &AuditConfig) -> Result<(), AuditError> {
    let now_ms = chrono::Utc::now().timestamp_millis();
    let cutoff = now_ms - (config.retention_days as i64) * DAY_MS;

    let deleted_old = conn.execute(DELETE_OLD_LOGS, [cutoff]).await?;
    if deleted_old > 0 {
        tracing::info!(rows = deleted_old, cutoff_ms = cutoff, "audit retention: time sweep");
    }

    let cap = config.per_entity_max_rows as i64;
    let mut entities: Vec<String> = Vec::new();
    {
        let mut rows = conn.query(LIST_ENTITIES, ()).await?;
        while let Some(row) = rows.next().await? {
            let name: String = row.get(0)?;
            entities.push(name);
        }
    }

    let mut trimmed_total: u64 = 0;
    for entity in &entities {
        let trimmed = conn
            .execute(
                TRIM_ENTITY_INDEX,
                turso::params![entity.as_str(), entity.as_str(), cap],
            )
            .await?;
        trimmed_total += trimmed;
    }
    if trimmed_total > 0 {
        tracing::info!(
            rows = trimmed_total,
            entities = entities.len(),
            cap,
            "audit retention: per-entity trim"
        );
    }

    // Reclaim freed pages. Best-effort — failure here only means the
    // file is slightly larger than ideal until the next sweep.
    // `incremental_vacuum` yields one row per page returned to the OS,
    // which `execute()` rejects; drain via `query()`.
    match conn.query("PRAGMA incremental_vacuum", ()).await {
        Ok(mut rows) => {
            while let Ok(Some(_)) = rows.next().await {}
        }
        Err(e) => {
            tracing::debug!(error = %e, "audit retention: incremental_vacuum failed");
        }
    }

    Ok(())
}
