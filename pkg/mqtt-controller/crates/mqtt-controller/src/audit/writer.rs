//! Async writer task that persists [`DecisionLogEntry`] records.
//!
//! Receives entries on a bounded channel from the daemon event loop,
//! batches them up to either the configured row cap or flush interval
//! (whichever fires first), and commits each batch in a single explicit
//! transaction. The producer side ([`AuditWriterHandle::try_send`]) is
//! non-blocking — if the queue is full the entry is dropped with a
//! warning rather than stalling the event loop on disk I/O.

use std::time::Duration;

use mqtt_controller_wire::DecisionLogEntry;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use turso::{Connection, Database, params};

use super::{AuditConfig, AuditError, apply_pragmas};

/// Producer-side capacity. Sized for ~50× the expected steady-state
/// flush batch so a brief disk stall doesn't drop entries on a busy
/// host.
const CHANNEL_CAPACITY: usize = 4096;

const INSERT_LOG_SQL: &str = "INSERT INTO decision_log \
    (ts_ms, event_summary, decisions_json, actions_json) \
    VALUES (?, ?, ?, ?) RETURNING id";

const INSERT_ENTITY_SQL: &str = "INSERT OR IGNORE INTO decision_log_entity \
    (entity, log_id, ts_ms) VALUES (?, ?, ?)";

/// Cheaply-cloneable sender. One handle per producer; the underlying
/// channel is multi-producer.
#[derive(Clone)]
pub struct AuditWriterHandle {
    tx: mpsc::Sender<DecisionLogEntry>,
}

impl AuditWriterHandle {
    /// Best-effort enqueue. If the writer is overwhelmed (channel full)
    /// or has shut down (channel closed), the entry is dropped and a
    /// warning is logged. Never blocks; never returns an error to the
    /// caller — a slow disk must not stall the event loop.
    pub fn try_send(&self, entry: DecisionLogEntry) {
        match self.tx.try_send(entry) {
            Ok(()) => {}
            Err(mpsc::error::TrySendError::Full(_)) => {
                tracing::warn!("audit log queue full; dropping decision log entry");
            }
            Err(mpsc::error::TrySendError::Closed(_)) => {
                tracing::warn!("audit log writer task gone; dropping decision log entry");
            }
        }
    }
}

/// Spawn the writer task. Returns a producer handle and the task's
/// `JoinHandle` (the caller should hold it for graceful shutdown but
/// abandoning it is also safe — the task exits cleanly when all
/// producer handles are dropped).
pub fn spawn(db: Database, config: AuditConfig) -> (AuditWriterHandle, JoinHandle<()>) {
    let (tx, rx) = mpsc::channel(CHANNEL_CAPACITY);
    let handle = tokio::spawn(writer_loop(db, config, rx));
    (AuditWriterHandle { tx }, handle)
}

async fn writer_loop(
    db: Database,
    config: AuditConfig,
    mut rx: mpsc::Receiver<DecisionLogEntry>,
) {
    let conn = match db.connect() {
        Ok(c) => c,
        Err(e) => {
            tracing::error!(error = %e, "audit writer: failed to obtain connection; task exiting");
            return;
        }
    };
    if let Err(e) = apply_pragmas(&conn).await {
        tracing::error!(error = %e, "audit writer: failed to apply pragmas; task exiting");
        return;
    }

    let interval = Duration::from_millis(config.flush_interval_ms);
    let max_batch = config.flush_max_rows.max(1);
    let mut buf: Vec<DecisionLogEntry> = Vec::with_capacity(max_batch);

    loop {
        // Block until at least one entry is available, then drain up
        // to the batch cap or until the interval elapses.
        let first = match rx.recv().await {
            Some(e) => e,
            None => break,
        };
        buf.push(first);

        let deadline = tokio::time::Instant::now() + interval;
        while buf.len() < max_batch {
            tokio::select! {
                msg = rx.recv() => match msg {
                    Some(e) => buf.push(e),
                    None => {
                        // Channel closed: flush what we have and exit.
                        if let Err(e) = flush(&conn, &buf).await {
                            tracing::error!(error = %e, batch = buf.len(), "audit writer: final flush failed");
                        }
                        return;
                    }
                },
                _ = tokio::time::sleep_until(deadline) => break,
            }
        }

        if let Err(e) = flush(&conn, &buf).await {
            tracing::error!(error = %e, batch = buf.len(), "audit writer: flush failed; dropping batch");
        }
        buf.clear();
    }
}

async fn flush(conn: &Connection, batch: &[DecisionLogEntry]) -> Result<(), AuditError> {
    if batch.is_empty() {
        return Ok(());
    }

    // Explicit BEGIN/COMMIT. Avoids depending on the higher-level
    // Transaction wrapper whose 0.5.x API surface is sparsely documented;
    // `BEGIN IMMEDIATE` matches what `Transaction::new` would issue
    // anyway.
    conn.execute("BEGIN IMMEDIATE", ()).await?;

    if let Err(e) = insert_batch(conn, batch).await {
        // Best-effort rollback. If even ROLLBACK fails the connection is
        // unusable; log and propagate the original error.
        let _ = conn.execute("ROLLBACK", ()).await;
        return Err(e);
    }

    conn.execute("COMMIT", ()).await?;
    Ok(())
}

async fn insert_batch(conn: &Connection, batch: &[DecisionLogEntry]) -> Result<(), AuditError> {
    for entry in batch {
        let ts_ms = entry.timestamp_epoch_ms as i64;
        let decisions_json =
            serde_json::to_string(&entry.decisions).unwrap_or_else(|_| "[]".to_string());
        let actions_json =
            serde_json::to_string(&entry.actions_emitted).unwrap_or_else(|_| "[]".to_string());

        let mut rows = conn
            .query(
                INSERT_LOG_SQL,
                params![
                    ts_ms,
                    entry.event_summary.as_str(),
                    decisions_json.as_str(),
                    actions_json.as_str()
                ],
            )
            .await?;

        let log_id: i64 = match rows.next().await? {
            Some(row) => row.get(0)?,
            None => {
                tracing::warn!("audit writer: INSERT RETURNING produced no row");
                continue;
            }
        };
        // Drop the Rows iterator so the connection is free for the
        // next statement.
        drop(rows);

        for entity in &entry.involved_entities {
            conn.execute(
                INSERT_ENTITY_SQL,
                params![entity.as_str(), log_id, ts_ms],
            )
            .await?;
        }
    }
    Ok(())
}
