//! Scrolling event/decision log.

use leptos::prelude::*;

use mqtt_controller_wire::DecisionLogEntry;

use crate::ws::WsState;

#[component]
pub fn EventLog() -> impl IntoView {
    let ws = expect_context::<WsState>();
    let entries = ws.log_entries;

    view! {
        <div class="log-list">
            {move || {
                entries.get().iter().map(|entry| {
                    let entry = entry.clone();
                    view! { <LogEntry entry=entry /> }
                }).collect::<Vec<_>>()
            }}
        </div>
    }
}

#[component]
fn LogEntry(entry: DecisionLogEntry) -> impl IntoView {
    let time = format_epoch_ms(entry.timestamp_epoch_ms);
    let summary = entry.event_summary.clone();

    let decisions_div = if !entry.decisions.is_empty() {
        let text = entry.decisions.join("; ");
        Some(view! { <div class="decisions">{text}</div> })
    } else {
        None
    };

    let actions_div = if !entry.actions_emitted.is_empty() {
        let text = entry
            .actions_emitted
            .iter()
            .map(|a| format!("{} -> {}", a.target, a.payload_json))
            .collect::<Vec<_>>()
            .join("; ");
        Some(view! { <div class="actions">{text}</div> })
    } else {
        None
    };

    view! {
        <div class="log-entry">
            <span class="timestamp">{time}</span>
            <span class="event-summary">{summary}</span>
            {decisions_div}
            {actions_div}
        </div>
    }
}

fn format_epoch_ms(ms: u64) -> String {
    let secs = (ms / 1000) % 86400;
    let h = secs / 3600;
    let m = (secs % 3600) / 60;
    let s = secs % 60;
    format!("{h:02}:{m:02}:{s:02}")
}
