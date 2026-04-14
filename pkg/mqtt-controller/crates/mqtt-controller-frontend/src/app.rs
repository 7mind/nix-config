//! Root application component with tab navigation.

use leptos::prelude::*;

use crate::components::event_log::EventLog;
use crate::components::heating_card::HeatingCards;
use crate::components::plug_card::PlugCards;
use crate::components::room_card::RoomCards;
use crate::ws::WsState;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tab {
    Rooms,
    Plugs,
    Heating,
}

impl Tab {
    fn from_hash(hash: &str) -> Self {
        match hash.trim_start_matches('#') {
            "plugs" => Tab::Plugs,
            "heating" => Tab::Heating,
            _ => Tab::Rooms,
        }
    }

    fn to_hash(self) -> &'static str {
        match self {
            Tab::Rooms => "#rooms",
            Tab::Plugs => "#plugs",
            Tab::Heating => "#heating",
        }
    }
}

#[component]
pub fn App() -> impl IntoView {
    let ws = WsState::new();
    provide_context(ws.clone());

    let initial_tab = web_sys::window()
        .and_then(|w| w.location().hash().ok())
        .map(|h| Tab::from_hash(&h))
        .unwrap_or(Tab::Rooms);

    let (active_tab, set_active_tab) = signal(initial_tab);

    // Sync tab changes to URL hash.
    Effect::new(move |_| {
        let tab = active_tab.get();
        if let Some(window) = web_sys::window() {
            let _ = window.location().set_hash(tab.to_hash());
        }
    });
    provide_context(active_tab);

    // Auto-set entity filter based on active tab + topology.
    let topology = ws.topology;
    let set_filter = ws.set_filter_entities;
    Effect::new(move |_| {
        let tab = active_tab.get();
        let Some(topo) = topology.get() else { return };
        let mut entities = std::collections::BTreeSet::new();
        match tab {
            Tab::Rooms => {
                for room in &topo.rooms {
                    entities.insert(room.name.clone());
                    entities.insert(room.group_name.clone());
                }
            }
            Tab::Plugs => {
                for plug in &topo.plugs {
                    entities.insert(plug.clone());
                }
            }
            Tab::Heating => {
                for zone in &topo.heating_zones {
                    entities.insert(zone.name.clone());
                    entities.insert(zone.relay_device.clone());
                    for trv in &zone.trv_devices {
                        entities.insert(trv.clone());
                    }
                }
            }
        }
        set_filter.set(entities);
    });

    view! {
        <div class="app">
            <header>
                <h1>"MQTT Controller"</h1>
                <div class="tab-bar">
                    <TabButton tab=Tab::Rooms active=active_tab set_active=set_active_tab label="Rooms" />
                    <TabButton tab=Tab::Plugs active=active_tab set_active=set_active_tab label="Plugs" />
                    <TabButton tab=Tab::Heating active=active_tab set_active=set_active_tab label="Heating" />
                    <button
                        class="btn"
                        on:click={
                            let set_filter = ws.set_filter_entities;
                            move |_| set_filter.set(std::collections::BTreeSet::new())
                        }
                    >
                        "Unselect all"
                    </button>
                </div>
                <ConnectionBadge ws=ws.clone() />
            </header>
            <div class="dashboard">
                {move || match active_tab.get() {
                    Tab::Rooms => view! {
                        <section>
                            <RoomCards />
                        </section>
                    }.into_any(),
                    Tab::Plugs => view! {
                        <section>
                            <PlugCards />
                        </section>
                    }.into_any(),
                    Tab::Heating => view! {
                        <section>
                            <HeatingCards />
                        </section>
                    }.into_any(),
                }}
                <section class="event-log">
                    <h2>"Event Log"</h2>
                    <EventLog />
                </section>
            </div>
        </div>
    }
}

#[component]
fn TabButton(
    tab: Tab,
    active: ReadSignal<Tab>,
    set_active: WriteSignal<Tab>,
    label: &'static str,
) -> impl IntoView {
    view! {
        <button
            class=move || if active.get() == tab { "tab-btn active" } else { "tab-btn" }
            on:click=move |_| set_active.set(tab)
        >
            {label}
        </button>
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
