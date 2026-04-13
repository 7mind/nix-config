//! Heating zone cards showing relay state and TRV details.

use leptos::prelude::*;

use mqtt_controller_wire::HeatingZoneSnapshot;

use crate::ws::WsState;

#[component]
pub fn HeatingCards() -> impl IntoView {
    let ws = expect_context::<WsState>();
    let snapshot = ws.snapshot;

    view! {
        <div class="card-grid">
            {move || {
                snapshot.get().map(|snap| {
                    snap.heating_zones.iter().map(|zone| {
                        let zone = zone.clone();
                        view! { <HeatingZoneCard zone=zone /> }
                    }).collect::<Vec<_>>()
                }).unwrap_or_default()
            }}
        </div>
    }
}

#[component]
fn HeatingZoneCard(zone: HeatingZoneSnapshot) -> impl IntoView {
    let ws = expect_context::<WsState>();
    let relay_class = if zone.relay_on {
        "status-dot on"
    } else {
        "status-dot off"
    };
    let relay_text = if !zone.relay_state_known {
        "relay: ?".to_string()
    } else if zone.relay_on {
        "relay: ON".to_string()
    } else {
        "relay: OFF".to_string()
    };

    let filter_name = zone.name.clone();
    let detail_name = zone.name.clone();
    let display_name = zone.name.clone();
    let json_text = serde_json::to_string_pretty(&zone).unwrap_or_default();

    let filter_ws = ws.clone();
    let filter_entities = ws.filter_entities;
    let detail_entity = ws.detail_entity;
    let detail_ws = ws.clone();

    let filter_name_cb = filter_name.clone();

    let trv_views: Vec<_> = zone
        .trvs
        .iter()
        .map(|trv| {
            let temp = trv
                .local_temperature
                .map(|t| format!("{t:.1}\u{00b0}C"))
                .unwrap_or_else(|| "?\u{00b0}C".into());
            let setpoint = trv
                .setpoint
                .map(|s| format!(" \u{2192} {s:.1}\u{00b0}C"))
                .unwrap_or_default();
            let demand = trv
                .pi_heating_demand
                .map(|d| format!(" {d}%"))
                .unwrap_or_default();
            let battery = trv
                .battery
                .map(|b| format!(" bat:{b}%"))
                .unwrap_or_default();

            let rs_class = match trv.running_state.as_str() {
                "heat" => "badge heat",
                "idle" => "badge idle",
                _ => "badge unknown",
            };

            let inhibited_badge = trv.inhibited.then(|| {
                view! { <span class="badge inhibited">"window"</span> }
            });
            let forced_badge = trv.forced.then(|| {
                view! { <span class="badge unknown">"forced"</span> }
            });

            let device = trv.device.clone();

            let schedule_view = if !trv.schedule.is_empty() {
                let name = trv.schedule.clone();
                let rows = parse_schedule_rows(&trv.schedule_summary);
                Some(view! {
                    <details class="schedule-popup">
                        <summary class="badge schedule-badge">{name}</summary>
                        <table class="schedule-table">
                            <thead><tr><th>"Time"</th><th>"Setpoint"</th></tr></thead>
                            <tbody>
                                {rows.into_iter().map(|(time, setpoint)| view! {
                                    <tr><td>{time}</td><td>{setpoint}</td></tr>
                                }).collect::<Vec<_>>()}
                            </tbody>
                        </table>
                    </details>
                })
            } else {
                None
            };

            view! {
                <div class="trv-row">
                    <span class="trv-device">{device}</span>
                    {schedule_view}
                    <span class="trv-temp">{temp}{setpoint}</span>
                    <span class=rs_class>{trv.running_state.clone()}{demand}</span>
                    {inhibited_badge}
                    {forced_badge}
                    <span class="trv-battery">{battery}</span>
                </div>
            }
        })
        .collect();

    view! {
        <div class="card heating-card">
            <div class="card-header">
                <input
                    type="checkbox"
                    class="entity-filter-cb"
                    prop:checked=move || filter_entities.get().contains(&filter_name_cb)
                    on:change={
                        let name = filter_name.clone();
                        move |_| filter_ws.toggle_filter(&name)
                    }
                />
                <span class=relay_class></span>
                <span class="card-name">{display_name.clone()}</span>
                <button
                    class="btn detail-btn"
                    on:click={
                        let name = detail_name.clone();
                        move |_| {
                            detail_ws.set_detail_entity.update(|current| {
                                if current.as_deref() == Some(&name) {
                                    *current = None;
                                } else {
                                    *current = Some(name.clone());
                                }
                            });
                        }
                    }
                >
                    "JSON"
                </button>
            </div>
            <div class="card-meta">
                <span>{relay_text}</span>
                <span class="relay-device">{format!(" ({})", zone.relay_device)}</span>
                {(zone.relay_stale).then(|| view! {
                    <span class="badge inhibited">" stale"</span>
                })}
                {(zone.min_cycle_remaining_secs > 0).then(|| view! {
                    <span class="badge unknown">{format!(" min_cycle {}s", zone.min_cycle_remaining_secs)}</span>
                })}
                {(zone.min_pause_remaining_secs > 0).then(|| view! {
                    <span class="badge unknown">{format!(" min_pause {}s", zone.min_pause_remaining_secs)}</span>
                })}
            </div>
            <div class="trv-list">
                {trv_views}
            </div>
            {move || {
                let show = detail_entity.get().as_deref() == Some(display_name.as_str());
                show.then(|| view! {
                    <pre class="json-detail">{json_text.clone()}</pre>
                })
            }}
        </div>
    }
}

/// Parse "00:00–06:00 → 21°C, 06:00–23:00 → 18°C" into (time, setpoint) rows.
fn parse_schedule_rows(summary: &str) -> Vec<(String, String)> {
    if summary.is_empty() {
        return Vec::new();
    }
    summary
        .split(", ")
        .filter_map(|segment| {
            let (time, setpoint) = segment.split_once(" \u{2192} ")?;
            Some((time.to_string(), setpoint.to_string()))
        })
        .collect()
}
