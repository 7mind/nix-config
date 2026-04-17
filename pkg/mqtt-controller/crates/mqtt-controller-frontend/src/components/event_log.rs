//! Event/decision log with entity filtering, keyed diffing, and toolbar.

use std::collections::BTreeSet;

use leptos::prelude::*;

use mqtt_controller_wire::DecisionLogEntry;

use crate::ws::WsState;

#[component]
pub fn EventLog() -> impl IntoView {
    let ws = expect_context::<WsState>();
    let entries = ws.log_entries;
    let filter = ws.filter_entities;

    // Memoize the filtered entry list so downstream readers only
    // re-compute when entries or filter actually change.
    let filtered = Memo::new(move |_| {
        let filter_set = filter.get();
        let all = entries.get();
        if filter_set.is_empty() {
            all
        } else {
            all.into_iter()
                .filter(|e| e.involved_entities.iter().any(|n| filter_set.contains(n)))
                .collect()
        }
    });

    view! {
        <EventLogToolbar />
        <div class="log-list">
            <For
                each=move || filtered.get()
                key=|entry| entry.seq
                children=|entry| view! { <LogEntry entry=entry /> }
            />
        </div>
    }
}

#[component]
fn EventLogToolbar() -> impl IntoView {
    let ws = expect_context::<WsState>();
    let ws_clear = ws.clone();
    let ws_copy = ws.clone();
    let ws_select_all = ws.clone();
    let ws_unselect_all = ws.clone();

    view! {
        <div class="log-toolbar">
            <button class="btn" on:click=move |_| ws_clear.clear_log()>"Clear"</button>
            <button
                class="btn"
                on:click=move |_| {
                    let entries = ws_copy.log_entries.get();
                    let filter = ws_copy.filter_entities.get();
                    copy_log_to_clipboard(entries, filter);
                }
            >"Copy"</button>
            <button
                class="btn"
                on:click=move |_| {
                    let all = all_known_entities(&ws_select_all);
                    ws_select_all.set_filter_entities.set(all);
                }
            >"Select all"</button>
            <button
                class="btn"
                on:click=move |_| {
                    ws_unselect_all.set_filter_entities.set(BTreeSet::new());
                }
            >"Unselect all"</button>
            <FilterSummary />
        </div>
    }
}

/// Union of every known entity name (rooms + their groups + plugs +
/// heating zones + relays + TRVs). Used by `Select all`.
fn all_known_entities(ws: &WsState) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    if let Some(topo) = ws.topology.get() {
        for room in &topo.rooms {
            out.insert(room.name.clone());
            out.insert(room.group_name.clone());
        }
        for plug in &topo.plugs {
            out.insert(plug.clone());
        }
        for zone in &topo.heating_zones {
            out.insert(zone.name.clone());
            out.insert(zone.relay_device.clone());
            for trv in &zone.trv_devices {
                out.insert(trv.clone());
            }
        }
    }
    out
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
                    format!("filter ({}): {}", set.len(), set.iter().cloned().collect::<Vec<_>>().join(", "))
                }
            }}
        </span>
    }
}

#[component]
fn LogEntry(entry: DecisionLogEntry) -> impl IntoView {
    let time = format_epoch_ms(entry.timestamp_epoch_ms);
    let summary = entry.event_summary.clone();

    let decisions_div = (!entry.decisions.is_empty()).then(|| {
        view! { <div class="decisions">{entry.decisions.join("; ")}</div> }
    });

    let actions_div = (!entry.actions_emitted.is_empty()).then(|| {
        let text = entry
            .actions_emitted
            .iter()
            .map(|a| format!("{} -> {}", a.target, a.payload_json))
            .collect::<Vec<_>>()
            .join("; ");
        view! { <div class="actions">{text}</div> }
    });

    let entities_text = (!entry.involved_entities.is_empty())
        .then(|| entry.involved_entities.join(", "));

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

fn copy_log_to_clipboard(entries: Vec<DecisionLogEntry>, filter: BTreeSet<String>) {
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
        let _ = clipboard.write_text(&text);
    }
}
