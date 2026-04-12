//! WebSocket connection manager with auto-reconnect.

use std::collections::BTreeSet;

use leptos::prelude::*;
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use web_sys::{CloseEvent, ErrorEvent, MessageEvent, WebSocket};

use mqtt_controller_wire::{
    ClientMessage, DecisionLogEntry, FullStateSnapshot, HeatingZoneSnapshot, RoomSnapshot,
    ServerMessage, TopologyInfo, PlugSnapshot,
};

const MAX_LOG_ENTRIES: usize = 200;
const RECONNECT_BASE_MS: u32 = 1000;
const RECONNECT_MAX_MS: u32 = 30000;

/// Reactive WebSocket state available to all components.
#[derive(Clone)]
pub struct WsState {
    pub connected: ReadSignal<bool>,
    pub snapshot: ReadSignal<Option<FullStateSnapshot>>,
    pub topology: ReadSignal<Option<TopologyInfo>>,
    pub log_entries: ReadSignal<Vec<DecisionLogEntry>>,
    /// Entity names selected for event log filtering. Empty = show all.
    pub filter_entities: ReadSignal<BTreeSet<String>>,
    pub set_filter_entities: WriteSignal<BTreeSet<String>>,
    /// Entity name whose JSON detail is expanded. None = all collapsed.
    pub detail_entity: ReadSignal<Option<String>>,
    pub set_detail_entity: WriteSignal<Option<String>>,
    ws: StoredValue<Option<WebSocket>>,
    set_connected: WriteSignal<bool>,
    set_snapshot: WriteSignal<Option<FullStateSnapshot>>,
    set_topology: WriteSignal<Option<TopologyInfo>>,
    set_log_entries: WriteSignal<Vec<DecisionLogEntry>>,
}

impl WsState {
    pub fn new() -> Self {
        let (connected, set_connected) = signal(false);
        let (snapshot, set_snapshot) = signal(None::<FullStateSnapshot>);
        let (topology, set_topology) = signal(None::<TopologyInfo>);
        let (log_entries, set_log_entries) = signal(Vec::<DecisionLogEntry>::new());
        let (filter_entities, set_filter_entities) = signal(BTreeSet::<String>::new());
        let (detail_entity, set_detail_entity) = signal(None::<String>);
        let ws = StoredValue::new(None::<WebSocket>);

        let state = Self {
            connected,
            snapshot,
            topology,
            log_entries,
            filter_entities,
            set_filter_entities,
            detail_entity,
            set_detail_entity,
            ws,
            set_connected,
            set_snapshot,
            set_topology,
            set_log_entries,
        };
        state.connect(0);
        state
    }

    /// Clear the event log.
    pub fn clear_log(&self) {
        self.set_log_entries.set(Vec::new());
    }

    /// Toggle an entity in the filter set.
    pub fn toggle_filter(&self, entity: &str) {
        self.set_filter_entities.update(|set| {
            if !set.remove(entity) {
                set.insert(entity.to_string());
            }
        });
    }

    /// Send a client message through the WebSocket.
    pub fn send(&self, msg: &ClientMessage) {
        if let Some(ws) = self.ws.get_value() {
            if ws.ready_state() == WebSocket::OPEN {
                if let Ok(json) = serde_json::to_string(msg) {
                    let _ = ws.send_with_str(&json);
                }
            }
        }
    }

    fn connect(&self, attempt: u32) {
        let url = build_ws_url();
        let ws = match WebSocket::new(&url) {
            Ok(ws) => ws,
            Err(_) => {
                self.schedule_reconnect(attempt);
                return;
            }
        };
        ws.set_binary_type(web_sys::BinaryType::Arraybuffer);

        let set_connected = self.set_connected;
        let set_snapshot = self.set_snapshot;
        let set_topology = self.set_topology;
        let set_log_entries = self.set_log_entries;

        // On open: mark connected, request state + topology.
        let ws_clone = ws.clone();
        let on_open = Closure::<dyn Fn()>::new(move || {
            set_connected.set(true);
            let _ = ws_clone.send_with_str(
                &serde_json::to_string(&ClientMessage::GetState).unwrap(),
            );
            let _ = ws_clone.send_with_str(
                &serde_json::to_string(&ClientMessage::GetTopology).unwrap(),
            );
        });
        ws.set_onopen(Some(on_open.as_ref().unchecked_ref()));
        on_open.forget();

        // On message: dispatch ServerMessage variants.
        let on_message = Closure::<dyn Fn(MessageEvent)>::new(move |e: MessageEvent| {
            if let Ok(text) = e.data().dyn_into::<js_sys::JsString>() {
                let s: String = text.into();
                if let Ok(msg) = serde_json::from_str::<ServerMessage>(&s) {
                    match msg {
                        ServerMessage::StateSnapshot(snap) => {
                            set_snapshot.set(Some(snap));
                        }
                        ServerMessage::Topology(topo) => {
                            set_topology.set(Some(topo));
                        }
                        ServerMessage::EventLog(entry) => {
                            set_log_entries.update(|entries| {
                                entries.insert(0, entry);
                                entries.truncate(MAX_LOG_ENTRIES);
                            });
                        }
                        ServerMessage::RoomUpdate(room) => {
                            set_snapshot.update(|snap| {
                                if let Some(snap) = snap {
                                    update_room_in_snapshot(snap, room);
                                }
                            });
                        }
                        ServerMessage::PlugUpdate(plug) => {
                            set_snapshot.update(|snap| {
                                if let Some(snap) = snap {
                                    update_plug_in_snapshot(snap, plug);
                                }
                            });
                        }
                        ServerMessage::HeatingZoneUpdate(zone) => {
                            set_snapshot.update(|snap| {
                                if let Some(snap) = snap {
                                    update_heating_zone_in_snapshot(snap, zone);
                                }
                            });
                        }
                    }
                }
            }
        });
        ws.set_onmessage(Some(on_message.as_ref().unchecked_ref()));
        on_message.forget();

        // On error: log it.
        let on_error = Closure::<dyn Fn(ErrorEvent)>::new(move |_e: ErrorEvent| {
            web_sys::console::warn_1(&"WebSocket error".into());
        });
        ws.set_onerror(Some(on_error.as_ref().unchecked_ref()));
        on_error.forget();

        // On close: mark disconnected, schedule reconnect.
        let state = self.clone();
        let on_close = Closure::<dyn Fn(CloseEvent)>::new(move |_e: CloseEvent| {
            state.set_connected.set(false);
            state.ws.set_value(None);
            state.schedule_reconnect(attempt + 1);
        });
        ws.set_onclose(Some(on_close.as_ref().unchecked_ref()));
        on_close.forget();

        self.ws.set_value(Some(ws));
    }

    fn schedule_reconnect(&self, attempt: u32) {
        let delay = std::cmp::min(
            RECONNECT_BASE_MS * 2u32.saturating_pow(attempt),
            RECONNECT_MAX_MS,
        );
        let state = self.clone();
        gloo_timers::callback::Timeout::new(delay, move || {
            state.connect(attempt);
        })
        .forget();
    }
}

fn build_ws_url() -> String {
    let window = web_sys::window().unwrap();
    let location = window.location();
    let host = location.host().unwrap_or_else(|_| "localhost:8780".into());
    let protocol = location.protocol().unwrap_or_else(|_| "http:".into());
    let ws_protocol = if protocol == "https:" { "wss:" } else { "ws:" };
    format!("{ws_protocol}//{host}/ws")
}

fn update_room_in_snapshot(snap: &mut FullStateSnapshot, room: RoomSnapshot) {
    if let Some(existing) = snap.rooms.iter_mut().find(|r| r.name == room.name) {
        *existing = room;
    } else {
        snap.rooms.push(room);
    }
}

fn update_plug_in_snapshot(snap: &mut FullStateSnapshot, plug: PlugSnapshot) {
    if let Some(existing) = snap.plugs.iter_mut().find(|p| p.device == plug.device) {
        *existing = plug;
    } else {
        snap.plugs.push(plug);
    }
}

fn update_heating_zone_in_snapshot(snap: &mut FullStateSnapshot, zone: HeatingZoneSnapshot) {
    if let Some(existing) = snap.heating_zones.iter_mut().find(|z| z.name == zone.name) {
        *existing = zone;
    } else {
        snap.heating_zones.push(zone);
    }
}
