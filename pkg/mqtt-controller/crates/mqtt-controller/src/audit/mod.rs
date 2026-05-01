//! Persistent audit log of decision-log entries.
//!
//! The daemon's event loop already builds a [`mqtt_controller_wire::DecisionLogEntry`]
//! per processed event that produced visible effects or captured decisions.
//! That entry is broadcast to live WebSocket clients; this module persists
//! the same entries to a Turso database so the per-device popup in the web
//! dashboard can show history that survives daemon restarts.
//!
//! ## Design
//!
//! * **Storage**: Turso (pure-Rust SQLite rewrite, on-disk-compatible with
//!   SQLite). One file at `AuditConfig::path`.
//! * **Schema**: see [`schema`]. One row per processed event in
//!   `decision_log`; a many-to-many entity index in `decision_log_entity`
//!   so per-entity queries are an indexed range scan.
//! * **Write path**: a dedicated tokio task (`writer`) drains an
//!   `mpsc::Receiver<DecisionLogEntry>` and batches commits. Synchronous=NORMAL
//!   plus batching keeps fsync amplification low without losing crash
//!   consistency.
//! * **Retention**: a periodic task (`retention`) runs hourly, deletes by
//!   `ts_ms < cutoff` and trims per-entity history to a row cap.
//! * **Read path**: [`query`] runs a single prepared statement per request.
//!
//! ## Status
//!
//! Turso is currently in beta. We accept occasional history loss as a
//! trade for the pure-Rust closure (no C dependency). The on-disk format
//! is wire-compatible with SQLite, so migrating to `rusqlite` later is a
//! drop-in change to this module.

pub mod query;
pub mod retention;
pub mod schema;
pub mod writer;

pub use query::{DEFAULT_LIMIT, MAX_LIMIT, fetch};
pub use retention::spawn as spawn_retention;
pub use writer::{AuditWriterHandle, spawn as spawn_writer};

use std::path::Path;

use serde::{Deserialize, Serialize};
use thiserror::Error;
use turso::{Builder, Connection, Database};

#[derive(Debug, Error)]
pub enum AuditError {
    #[error("turso: {0}")]
    Turso(#[from] turso::Error),
}

/// Runtime configuration for the audit subsystem. Surfaced in the
/// JSON config under `audit_log`; the NixOS module renders it from
/// `smind.services.mqtt-controller.audit_log`.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AuditConfig {
    /// Filesystem path of the database file. The parent directory must
    /// exist and be writable; in NixOS deployments this is the systemd
    /// `StateDirectory` (e.g. `/var/lib/mqtt-controller/audit.db`).
    pub path: std::path::PathBuf,
    /// Rows older than `now - retention_days` are deleted by the
    /// retention sweep.
    #[serde(default = "default_retention_days")]
    pub retention_days: u32,
    /// Per-entity row cap. The retention sweep keeps the most recent
    /// `per_entity_max_rows` rows per entity even if they fall outside
    /// the time window — guards against a noisy entity pushing out a
    /// quiet entity's history.
    #[serde(default = "default_per_entity_max_rows")]
    pub per_entity_max_rows: u32,
    /// Writer flush interval. Commits happen at most this often, even
    /// when the queue is empty.
    #[serde(default = "default_flush_interval_ms")]
    pub flush_interval_ms: u64,
    /// Writer flush row cap. A commit fires immediately once this many
    /// rows are buffered, regardless of the time-based interval.
    #[serde(default = "default_flush_max_rows")]
    pub flush_max_rows: usize,
    /// Retention sweep interval.
    #[serde(default = "default_sweep_interval_secs")]
    pub sweep_interval_secs: u64,
}

fn default_retention_days() -> u32 {
    30
}
fn default_per_entity_max_rows() -> u32 {
    2_000
}
fn default_flush_interval_ms() -> u64 {
    5_000
}
fn default_flush_max_rows() -> usize {
    100
}
fn default_sweep_interval_secs() -> u64 {
    3_600
}

/// Open the audit database. Creates the file if missing, applies
/// PRAGMAs and migrations, and returns a [`Database`] handle ready to
/// hand to the writer task.
pub async fn open(path: &Path) -> Result<Database, AuditError> {
    let path_str = path
        .to_str()
        .expect("audit db path must be utf-8");
    let db = Builder::new_local(path_str).build().await?;
    {
        let conn = db.connect()?;
        apply_pragmas(&conn).await?;
        run_migrations(&conn).await?;
    }
    Ok(db)
}

/// Apply per-connection PRAGMAs. Must be called on every connection
/// where `foreign_keys` enforcement matters (i.e. anywhere we delete
/// from `decision_log` and rely on cascades).
///
/// Uses `query()` rather than `execute()` because some PRAGMAs return
/// rows even when used as setters (notably `PRAGMA journal_mode = WAL`
/// which echoes back the resulting mode); `execute()` errors with
/// "unexpected row during execution" when that happens. We drain and
/// drop the rows.
pub async fn apply_pragmas(conn: &Connection) -> Result<(), AuditError> {
    for stmt in schema::PRAGMAS {
        let mut rows = conn.query(*stmt, ()).await?;
        while rows.next().await?.is_some() {}
    }
    Ok(())
}

async fn run_migrations(conn: &Connection) -> Result<(), AuditError> {
    for stmt in schema::MIGRATIONS {
        conn.execute(stmt, ()).await?;
    }
    Ok(())
}
