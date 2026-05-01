//! Schema for the audit-log database.
//!
//! Two tables. `decision_log` holds one row per processed event that
//! produced visible effects or captured decisions (the same filter the
//! WebSocket broadcast applies in `daemon::event_loop`). The auxiliary
//! `decision_log_entity` table is a many-to-many index of entity name
//! → log row, populated from `DecisionLogEntry::involved_entities`, so
//! the per-device popup query is a single index seek + ordered range.
//!
//! `STRICT` is on so column types are enforced. `id` is a synthetic
//! autoincrement key; the wire-side `seq` resets to 0 each daemon run
//! and is not stored.

/// Statements run on every open to bring an empty or pre-existing database
/// up to the current schema. Each statement is idempotent.
pub const MIGRATIONS: &[&str] = &[
    "CREATE TABLE IF NOT EXISTS decision_log (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        ts_ms           INTEGER NOT NULL,
        event_summary   TEXT    NOT NULL,
        decisions_json  TEXT    NOT NULL,
        actions_json    TEXT    NOT NULL
    ) STRICT",
    "CREATE INDEX IF NOT EXISTS idx_decision_log_ts \
        ON decision_log(ts_ms)",
    "CREATE TABLE IF NOT EXISTS decision_log_entity (
        entity   TEXT    NOT NULL,
        log_id   INTEGER NOT NULL REFERENCES decision_log(id) ON DELETE CASCADE,
        ts_ms   INTEGER NOT NULL,
        PRIMARY KEY (entity, log_id)
    ) STRICT",
    "CREATE INDEX IF NOT EXISTS idx_decision_log_entity_ts \
        ON decision_log_entity(entity, ts_ms DESC)",
];

/// PRAGMAs applied on every connection. WAL + NORMAL gives crash-consistent
/// durability with batched fsyncs, suitable for an audit log; foreign keys
/// must be enabled per-connection for ON DELETE CASCADE on the entity
/// index to fire during retention sweeps.
pub const PRAGMAS: &[&str] = &[
    "PRAGMA journal_mode = WAL",
    "PRAGMA synchronous = NORMAL",
    "PRAGMA foreign_keys = ON",
    "PRAGMA temp_store = MEMORY",
    "PRAGMA auto_vacuum = INCREMENTAL",
];
