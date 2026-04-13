//! Scrolling event/decision log with entity filtering and clear/copy.

use leptos::prelude::*;

use mqtt_controller_wire::DecisionLogEntry;

use crate::ws::WsState;

#[component]
pub fn EventLog() -> impl IntoView {
    let ws = expect_context::<WsState>();
    let entries = ws.log_entries;
    let filter = ws.filter_entities;

    let filtered = move || {
        let filter_set = filter.get();
        let all = entries.get();
        if filter_set.is_empty() {
            all
        } else {
            all.into_iter()
                .filter(|entry| {
                    entry
                        .involved_entities
                        .iter()
                        .any(|e| filter_set.contains(e))
                })
                .collect()
        }
    };

    let ws_clear = ws.clone();
    let filter_copy = ws.filter_entities;
    let entries_copy = ws.log_entries;

    view! {
        <div class="log-toolbar">
            <button
                class="btn"
                on:click=move |_| {
                    ws_clear.clear_log();
                }
            >
                "Clear"
            </button>
            <button
                class="btn"
                on:click=move |_| {
                    copy_log_to_clipboard(entries_copy.get(), filter_copy.get());
                }
            >
                "Copy"
            </button>
            <FilterSummary />
        </div>
        <div class="log-list">
            {move || {
                filtered().iter().map(|entry| {
                    let entry = entry.clone();
                    view! { <LogEntry entry=entry /> }
                }).collect::<Vec<_>>()
            }}
        </div>
    }
}

#[component]
fn FilterSummary() -> impl IntoView {
    let ws = expect_context::<WsState>();
    let filter = ws.filter_entities;

    view! {
        <span class="filter-summary">
            {move || {
                let set = filter.get();
                if set.is_empty() {
                    "showing all".to_string()
                } else {
                    let names: Vec<_> = set.iter().cloned().collect();
                    format!("filter: {}", names.join(", "))
                }
            }}
        </span>
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

    let entities_text = if !entry.involved_entities.is_empty() {
        Some(entry.involved_entities.join(", "))
    } else {
        None
    };

    view! {
        <div class="log-entry">
            <span class="timestamp">{time}</span>
            <span class="event-summary">{summary}</span>
            {entities_text.map(|t| view! { <span class="involved-entities">{t}</span> })}
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

fn copy_log_to_clipboard(
    entries: Vec<DecisionLogEntry>,
    filter: std::collections::BTreeSet<String>,
) {
    let filtered: Vec<_> = if filter.is_empty() {
        entries
    } else {
        entries
            .into_iter()
            .filter(|e| e.involved_entities.iter().any(|n| filter.contains(n)))
            .collect()
    };

    let text = filtered
        .iter()
        .map(|e| {
            let time = format_epoch_ms(e.timestamp_epoch_ms);
            let actions = e
                .actions_emitted
                .iter()
                .map(|a| format!("  {} -> {}", a.target, a.payload_json))
                .collect::<Vec<_>>()
                .join("\n");
            let decisions = if e.decisions.is_empty() {
                String::new()
            } else {
                format!("  decisions: {}", e.decisions.join("; "))
            };
            format!(
                "[{time}] {}{}\n{}",
                e.event_summary,
                if decisions.is_empty() {
                    String::new()
                } else {
                    format!("\n{decisions}")
                },
                if actions.is_empty() {
                    String::new()
                } else {
                    format!("{actions}\n")
                }
            )
        })
        .collect::<Vec<_>>()
        .join("\n");

    if let Some(window) = web_sys::window() {
        let clipboard = window.navigator().clipboard();
        let _: js_sys::Promise = clipboard.write_text(&text);
    }
}
