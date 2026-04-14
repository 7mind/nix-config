//! Plug state cards with toggle control.

use leptos::prelude::*;

use mqtt_controller_wire::{ClientMessage, PlugSnapshot};

use crate::ws::WsState;

#[component]
pub fn PlugCards() -> impl IntoView {
    let ws = expect_context::<WsState>();
    let snapshot = ws.snapshot;

    view! {
        <div class="card-grid">
            {move || {
                snapshot.get().map(|snap| {
                    snap.plugs.iter().map(|plug| {
                        let plug = plug.clone();
                        view! { <PlugCard plug=plug /> }
                    }).collect::<Vec<_>>()
                }).unwrap_or_default()
            }}
        </div>
    }
}

#[component]
fn PlugCard(plug: PlugSnapshot) -> impl IntoView {
    let ws = expect_context::<WsState>();
    let on_class = if plug.on { "status-dot on" } else { "status-dot off" };
    let toggle_device = plug.device.clone();
    let display_device = plug.device.clone();
    let filter_name = plug.device.clone();
    let detail_name = plug.device.clone();

    let status_text = if plug.on { "ON" } else { "OFF" };
    let power_text = plug.power_watts.map(|w| format!(" {w:.1}W")).unwrap_or_default();
    let meta_text = format!("{status_text}{power_text}");

    // Kill-switch countdown badge: shows remaining time before auto-off.
    let kill_switch_badge = plug.idle_since_ago_ms.and_then(|elapsed_ms| {
        let holdoff_secs = plug.kill_switch_holdoff_secs?;
        let elapsed_secs = elapsed_ms / 1000;
        let remaining = holdoff_secs.saturating_sub(elapsed_secs);
        let total_min = holdoff_secs / 60;
        let text = if remaining < 60 {
            format!("kill: {remaining}s / {total_min}m")
        } else {
            format!("kill: {}m / {total_min}m", remaining / 60)
        };
        Some(text)
    });

    let json_text = serde_json::to_string_pretty(&plug).unwrap_or_default();

    let filter_ws = ws.clone();
    let filter_entities = ws.filter_entities;
    let detail_entity = ws.detail_entity;
    let detail_ws = ws.clone();

    let filter_name_cb = filter_name.clone();

    view! {
        <div class="card">
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
                <span class=on_class></span>
                <span class="card-name">{display_device.clone()}</span>
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
                {meta_text}
                {kill_switch_badge.map(|text| view! {
                    <span class="badge kill-switch">{text}</span>
                })}
            </div>
            <div class="card-controls">
                <button
                    class="btn"
                    on:click=move |_| {
                        ws.send(&ClientMessage::TogglePlug { device: toggle_device.clone() });
                    }
                >
                    "Toggle"
                </button>
            </div>
            {move || {
                let show = detail_entity.get().as_deref() == Some(display_device.as_str());
                show.then(|| view! {
                    <pre class="json-detail">{json_text.clone()}</pre>
                })
            }}
        </div>
    }
}
