//! Heating-zone cards: relay + TRV rollup.

use leptos::prelude::*;

use mqtt_controller_wire::HeatingZoneSnapshot;

use crate::components::shared::{tass_state_row, EntityFilterCheckbox, JsonButton};
use crate::ws::WsState;

#[component]
pub fn HeatingCards() -> impl IntoView {
    let ws = expect_context::<WsState>();
    let heating_names = ws.heating_names;

    view! {
        <div class="card-grid">
            <For
                each=move || heating_names.get()
                key=|name| name.clone()
                children=move |name| {
                    view! { <HeatingZoneCard name=name /> }
                }
            />
        </div>
    }
}

#[component]
fn HeatingZoneCard(name: String) -> impl IntoView {
    let ws = expect_context::<WsState>();
    let Some(signal) = ws.heating_signal(&name) else {
        return view! { <div class="card">"(missing zone "{name}")"</div> }.into_any();
    };
    let display_name = name.clone();
    let display_name_title = name.clone();
    let json_name = name.clone();

    view! {
        <div class="card heating-card">
            <div class="card-header">
                <EntityFilterCheckbox name=name.clone() />
                <span class=move || if signal.with(|z| z.relay_on) { "status-dot on" } else { "status-dot off" }></span>
                <span class="card-name" title=display_name_title>{display_name}</span>
                <JsonButton
                    title=format!("Heating: {}", json_name)
                    build_json=move || serde_json::to_string_pretty(&signal.get()).unwrap_or_default()
                />
            </div>

            <HeatingMeta signal=signal />
            <HeatingTassLine signal=signal />
            <TrvList signal=signal />
        </div>
    }.into_any()
}

#[component]
fn HeatingTassLine(signal: RwSignal<HeatingZoneSnapshot>) -> impl IntoView {
    view! {
        {move || {
            let z = signal.get();
            tass_state_row(z.target, z.target_value, z.actual, z.actual_value)
        }}
    }
}

#[component]
fn HeatingMeta(signal: RwSignal<HeatingZoneSnapshot>) -> impl IntoView {
    view! {
        <div class="card-meta">
            {move || {
                let z = signal.get();
                let relay_text = if !z.relay_state_known {
                    "relay: ?".to_string()
                } else if z.relay_on {
                    "relay: ON".to_string()
                } else {
                    "relay: OFF".to_string()
                };
                view! {
                    <span>{relay_text}</span>
                    <span class="relay-device">{format!(" ({})", z.relay_device)}</span>
                    {z.relay_stale.then(|| view! { <span class="badge inhibited">" stale"</span> })}
                    {(z.min_cycle_remaining_secs > 0).then(|| view! {
                        <span class="badge unknown">{format!(" min_cycle {}s", z.min_cycle_remaining_secs)}</span>
                    })}
                    {(z.min_pause_remaining_secs > 0).then(|| view! {
                        <span class="badge unknown">{format!(" min_pause {}s", z.min_pause_remaining_secs)}</span>
                    })}
                }
            }}
        </div>
    }
}

#[component]
fn TrvList(signal: RwSignal<HeatingZoneSnapshot>) -> impl IntoView {
    view! {
        <div class="trv-list">
            {move || {
                let trvs = signal.with(|z| z.trvs.clone());
                trvs.into_iter().map(|trv| {
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
                    let inhibited_badge = trv.inhibited.then(|| view! {
                        <span class="badge inhibited">"window"</span>
                    });
                    let forced_badge = trv.forced.then(|| view! {
                        <span class="badge unknown">"forced"</span>
                    });
                    let schedule_view = (!trv.schedule.is_empty()).then(|| {
                        let rows = parse_schedule_rows(&trv.schedule_summary);
                        view! {
                            <details class="schedule-popup">
                                <summary class="badge schedule-badge">{trv.schedule.clone()}</summary>
                                <table class="schedule-table">
                                    <thead><tr><th>"Time"</th><th>"Setpoint"</th></tr></thead>
                                    <tbody>
                                        {rows.into_iter().map(|(time, setpoint)| view! {
                                            <tr><td>{time}</td><td>{setpoint}</td></tr>
                                        }).collect::<Vec<_>>()}
                                    </tbody>
                                </table>
                            </details>
                        }
                    });

                    let device_title = trv.device.clone();
                    view! {
                        <div class="trv-row" title=device_title>
                            <span class="trv-device">{trv.device}</span>
                            {schedule_view}
                            <span class="trv-temp">{temp}{setpoint}</span>
                            <span class=rs_class>{trv.running_state.clone()}{demand}</span>
                            {inhibited_badge}
                            {forced_badge}
                            <span class="trv-battery">{battery}</span>
                        </div>
                    }
                }).collect::<Vec<_>>()
            }}
        </div>
    }
}

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
