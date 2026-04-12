//! Root application component.

use leptos::prelude::*;

use crate::components::event_log::EventLog;
use crate::components::plug_card::PlugCards;
use crate::components::room_card::RoomCards;
use crate::ws::WsState;

#[component]
pub fn App() -> impl IntoView {
    let ws = WsState::new();
    provide_context(ws.clone());

    view! {
        <div class="app">
            <header>
                <h1>"Hue Controller"</h1>
                <ConnectionBadge ws=ws.clone() />
            </header>
            <div class="dashboard">
                <section>
                    <h2>"Rooms"</h2>
                    <RoomCards />
                </section>
                <section>
                    <h2>"Plugs"</h2>
                    <PlugCards />
                </section>
                <section class="event-log">
                    <h2>"Event Log"</h2>
                    <EventLog />
                </section>
            </div>
        </div>
    }
}

#[component]
fn ConnectionBadge(ws: WsState) -> impl IntoView {
    let connected = ws.connected;
    view! {
        <span class=move || {
            if connected.get() { "connection-status connected" }
            else { "connection-status disconnected" }
        }>
            {move || if connected.get() { "connected" } else { "disconnected" }}
        </span>
    }
}
