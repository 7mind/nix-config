//! Plug state cards with toggle control.

use leptos::prelude::*;

use mqtt_controller_wire::ClientMessage;

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
                        let device = plug.device.clone();
                        let on = plug.on;
                        let idle_ms = plug.idle_since_ago_ms;
                        view! { <PlugCard device=device on=on idle_ms=idle_ms /> }
                    }).collect::<Vec<_>>()
                }).unwrap_or_default()
            }}
        </div>
    }
}

#[component]
fn PlugCard(device: String, on: bool, idle_ms: Option<u64>) -> impl IntoView {
    let ws = expect_context::<WsState>();
    let on_class = if on { "status-dot on" } else { "status-dot off" };
    let toggle_device = device.clone();
    let display_device = device.clone();

    let status_text = if on { "ON" } else { "OFF" };
    let idle_text = idle_ms.map(|ms| {
        let secs = ms / 1000;
        if secs < 60 {
            format!(" (idle {secs}s)")
        } else {
            format!(" (idle {}m)", secs / 60)
        }
    }).unwrap_or_default();
    let meta_text = format!("{status_text}{idle_text}");

    view! {
        <div class="card">
            <div class="card-header">
                <span class=on_class></span>
                <span class="card-name">{display_device}</span>
            </div>
            <div class="card-meta">
                {meta_text}
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
        </div>
    }
}
