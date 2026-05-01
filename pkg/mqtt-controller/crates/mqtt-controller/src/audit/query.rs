//! Read API for the audit log. Backs the WebSocket query the per-device
//! popup issues.

use mqtt_controller_wire::LogEntryDto;
use turso::{Database, params};

use super::{AuditError, apply_pragmas};

/// Default page size when the client does not specify one.
pub const DEFAULT_LIMIT: u32 = 50;
/// Hard ceiling on page size to bound popup query cost.
pub const MAX_LIMIT: u32 = 500;

const QUERY_BY_ENTITY: &str = "SELECT dl.id, dl.ts_ms, dl.event_summary, \
        dl.decisions_json, dl.actions_json \
    FROM decision_log_entity dle \
    JOIN decision_log dl ON dl.id = dle.log_id \
    WHERE dle.entity = ? AND dle.ts_ms < ? \
    ORDER BY dle.ts_ms DESC \
    LIMIT ?";

/// Run a per-entity log query. Opens a fresh connection (cheap with
/// Turso); enforces the limit cap and substitutes `i64::MAX` for the
/// "from the top" cursor.
pub async fn fetch(
    db: &Database,
    entity: &str,
    before_ts_ms: Option<i64>,
    limit: Option<u32>,
) -> Result<Vec<LogEntryDto>, AuditError> {
    let conn = db.connect()?;
    apply_pragmas(&conn).await?;

    let limit_i64 = limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT) as i64;
    let before = before_ts_ms.unwrap_or(i64::MAX);

    let mut rows = conn
        .query(QUERY_BY_ENTITY, params![entity, before, limit_i64])
        .await?;

    let mut out = Vec::new();
    while let Some(row) = rows.next().await? {
        let id: i64 = row.get(0)?;
        let ts_ms: i64 = row.get(1)?;
        let summary: String = row.get(2)?;
        let decisions_json: String = row.get(3)?;
        let actions_json: String = row.get(4)?;
        let decisions: Vec<String> =
            serde_json::from_str(&decisions_json).unwrap_or_default();
        let actions_emitted: Vec<mqtt_controller_wire::ActionDto> =
            serde_json::from_str(&actions_json).unwrap_or_default();
        out.push(LogEntryDto {
            id,
            timestamp_epoch_ms: ts_ms,
            event_summary: summary,
            decisions,
            actions_emitted,
        });
    }
    Ok(out)
}
