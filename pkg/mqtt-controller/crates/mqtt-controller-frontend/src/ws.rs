//! WebSocket connection manager with per-entity reactive signals.
//!
//! Each room/plug/heating-zone is stored as its own `RwSignal` in a
//! `BTreeMap` keyed by name. An incremental update mutates only the
//! affected signal, so unchanged cards are not re-rendered.
//!
//! A monotonic `tick_seq` signal increments every second so components
//! that display countdowns (kill-switch holdoff, motion cooldown) can
//! re-derive their displayed values without any server traffic.

use std::collections::{BTreeMap, BTreeSet};

use leptos::prelude::*;
use leptos::reactive::owner::LocalStorage;
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use web_sys::{CloseEvent, ErrorEvent, MessageEvent, WebSocket};

use mqtt_controller_wire::{
    ClientMessage, DecisionLogEntry, EntityUpdate, FullStateSnapshot, HeatingZoneSnapshot,
    LightSnapshot, PlugSnapshot, RoomSnapshot, ServerMessage, TopologyInfo,
};

const MAX_LOG_ENTRIES: usize = 200;
const RECONNECT_BASE_MS: u32 = 1000;
const RECONNECT_MAX_MS: u32 = 30000;
const TICK_INTERVAL_MS: u32 = 1000;

/// One JSON popup request: title and pretty-printed body.
#[derive(Clone, Debug, PartialEq)]
pub struct JsonPopup {
    pub title: String,
    pub json: String,
}

/// Held WebSocket resources. We keep the `Closure` handles alive so that
/// JS can invoke them, but drop them when we open a new connection so
/// the old ones are released (instead of leaking via `.forget()`).
struct WsInner {
    socket: Option<WebSocket>,
    on_open: Option<Closure<dyn Fn()>>,
    on_message: Option<Closure<dyn Fn(MessageEvent)>>,
    on_error: Option<Closure<dyn Fn(ErrorEvent)>>,
    on_close: Option<Closure<dyn Fn(CloseEvent)>>,
    reconnect: Option<gloo_timers::callback::Timeout>,
}

impl WsInner {
    fn new() -> Self {
        Self {
            socket: None,
            on_open: None,
            on_message: None,
            on_error: None,
            on_close: None,
            reconnect: None,
        }
    }
}

/// Arena-stored map of per-entity signals. LocalStorage lets us store
/// the BTreeMap (which holds signals that hand out shared ownership)
/// without requiring the map itself to be `Send + Sync` — `StoredValue`
/// itself is `Send + Sync` because it's just an arena key.
pub type EntityMap<T> = StoredValue<BTreeMap<String, RwSignal<T>>, LocalStorage>;

/// Reactive WebSocket state available to all components.
///
/// `Copy` because every field is either a `Signal` (already `Copy`) or a
/// `StoredValue` (ditto). That makes it cheap to pass through closures.
#[derive(Clone, Copy)]
pub struct WsState {
    pub connected: ReadSignal<bool>,
    pub topology: ReadSignal<Option<TopologyInfo>>,

    /// Ordered list of room names (drives the outer `<For>` loop).
    pub room_names: RwSignal<Vec<String>>,
    /// Ordered list of plug device names.
    pub plug_names: RwSignal<Vec<String>>,
    /// Ordered list of heating zone names.
    pub heating_names: RwSignal<Vec<String>>,
    /// Ordered list of individual light device names.
    pub light_names: RwSignal<Vec<String>>,

    /// Log entries (newest first).
    pub log_entries: ReadSignal<Vec<DecisionLogEntry>>,
    /// Entity names selected for event-log filtering. Empty = show all.
    pub filter_entities: ReadSignal<BTreeSet<String>>,
    pub set_filter_entities: WriteSignal<BTreeSet<String>>,

    /// Global JSON popup. `None` = hidden.
    pub json_popup: RwSignal<Option<JsonPopup>>,

    /// Monotonic counter ticking once per second. Components that
    /// display countdowns subscribe to this so they re-render as
    /// time progresses, without any server round-trip.
    pub tick_seq: ReadSignal<u64>,

    // --- internals ---
    rooms: EntityMap<RoomSnapshot>,
    plugs: EntityMap<PlugSnapshot>,
    heating: EntityMap<HeatingZoneSnapshot>,
    lights: EntityMap<LightSnapshot>,
    ws_inner: StoredValue<WsInner, LocalStorage>,
    set_connected: WriteSignal<bool>,
    set_topology: WriteSignal<Option<TopologyInfo>>,
    set_log_entries: WriteSignal<Vec<DecisionLogEntry>>,
}

impl WsState {
    pub fn new() -> Self {
        let (connected, set_connected) = signal(false);
        let (topology, set_topology) = signal(None::<TopologyInfo>);
        let (log_entries, set_log_entries) = signal(Vec::<DecisionLogEntry>::new());
        let (filter_entities, set_filter_entities) = signal(BTreeSet::<String>::new());
        let (tick_seq, set_tick_seq) = signal(0u64);

        let state = Self {
            connected,
            topology,
            room_names: RwSignal::new(Vec::new()),
            plug_names: RwSignal::new(Vec::new()),
            heating_names: RwSignal::new(Vec::new()),
            light_names: RwSignal::new(Vec::new()),
            log_entries,
            filter_entities,
            set_filter_entities,
            json_popup: RwSignal::new(None),
            tick_seq,
            rooms: StoredValue::new_local(BTreeMap::new()),
            plugs: StoredValue::new_local(BTreeMap::new()),
            heating: StoredValue::new_local(BTreeMap::new()),
            lights: StoredValue::new_local(BTreeMap::new()),
            ws_inner: StoredValue::new_local(WsInner::new()),
            set_connected,
            set_topology,
            set_log_entries,
        };
        state.start_tick(set_tick_seq);
        state.connect(0);
        state
    }

    /// Look up the reactive signal for a room by name.
    pub fn room_signal(&self, name: &str) -> Option<RwSignal<RoomSnapshot>> {
        self.rooms.with_value(|m| m.get(name).copied())
    }

    /// Look up the reactive signal for a plug by device name.
    pub fn plug_signal(&self, name: &str) -> Option<RwSignal<PlugSnapshot>> {
        self.plugs.with_value(|m| m.get(name).copied())
    }

    /// Look up the reactive signal for a heating zone by name.
    pub fn heating_signal(&self, name: &str) -> Option<RwSignal<HeatingZoneSnapshot>> {
        self.heating.with_value(|m| m.get(name).copied())
    }

    /// Look up the reactive signal for a light by device name.
    pub fn light_signal(&self, device: &str) -> Option<RwSignal<LightSnapshot>> {
        self.lights.with_value(|m| m.get(device).copied())
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
        let socket = self.ws_inner.with_value(|i| i.socket.clone());
        if let Some(ws) = socket {
            if ws.ready_state() == WebSocket::OPEN {
                if let Ok(json) = serde_json::to_string(msg) {
                    let _ = ws.send_with_str(&json);
                }
            }
        }
    }

    /// Show the JSON popup for an entity.
    pub fn show_json(&self, title: String, json: String) {
        self.json_popup.set(Some(JsonPopup { title, json }));
    }

    /// Hide the JSON popup.
    pub fn hide_json(&self) {
        self.json_popup.set(None);
    }

    fn start_tick(&self, set_tick: WriteSignal<u64>) {
        let tick = gloo_timers::callback::Interval::new(TICK_INTERVAL_MS, move || {
            set_tick.update(|n| *n = n.wrapping_add(1));
        });
        // The Interval runs for the lifetime of the app; forget is fine
        // (this runs once per process, not per reconnect).
        tick.forget();
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
        let set_topology = self.set_topology;
        let set_log_entries = self.set_log_entries;
        let rooms = self.rooms;
        let plugs = self.plugs;
        let heating = self.heating;
        let lights = self.lights;
        let room_names = self.room_names;
        let plug_names = self.plug_names;
        let heating_names = self.heating_names;
        let light_names = self.light_names;

        // On open: mark connected, request snapshot + topology.
        let ws_for_open = ws.clone();
        let on_open = Closure::<dyn Fn()>::new(move || {
            set_connected.set(true);
            let _ = ws_for_open.send_with_str(
                &serde_json::to_string(&ClientMessage::GetState).unwrap(),
            );
            let _ = ws_for_open.send_with_str(
                &serde_json::to_string(&ClientMessage::GetTopology).unwrap(),
            );
        });
        ws.set_onopen(Some(on_open.as_ref().unchecked_ref()));

        // On message: dispatch ServerMessage variants.
        let on_message = Closure::<dyn Fn(MessageEvent)>::new(move |e: MessageEvent| {
            let Ok(text) = e.data().dyn_into::<js_sys::JsString>() else {
                return;
            };
            let s: String = text.into();
            let Ok(msg) = serde_json::from_str::<ServerMessage>(&s) else {
                return;
            };
            match msg {
                ServerMessage::StateSnapshot(snap) => {
                    apply_full_snapshot(
                        rooms,
                        plugs,
                        heating,
                        lights,
                        room_names,
                        plug_names,
                        heating_names,
                        light_names,
                        snap,
                    );
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
                ServerMessage::Entity(update) => match update {
                    EntityUpdate::Room(room) => {
                        upsert_entity(rooms, room_names, room.name.clone(), room);
                    }
                    EntityUpdate::Plug(plug) => {
                        upsert_entity(plugs, plug_names, plug.device.clone(), plug);
                    }
                    EntityUpdate::HeatingZone(zone) => {
                        upsert_entity(heating, heating_names, zone.name.clone(), zone);
                    }
                    EntityUpdate::Light(light) => {
                        upsert_entity(lights, light_names, light.device.clone(), light);
                    }
                },
            }
        });
        ws.set_onmessage(Some(on_message.as_ref().unchecked_ref()));

        // On error: log it.
        let on_error = Closure::<dyn Fn(ErrorEvent)>::new(move |_e: ErrorEvent| {
            web_sys::console::warn_1(&"WebSocket error".into());
        });
        ws.set_onerror(Some(on_error.as_ref().unchecked_ref()));

        // On close: mark disconnected, schedule reconnect.
        let state = *self;
        let on_close = Closure::<dyn Fn(CloseEvent)>::new(move |_e: CloseEvent| {
            state.set_connected.set(false);
            state.schedule_reconnect(attempt + 1);
        });
        ws.set_onclose(Some(on_close.as_ref().unchecked_ref()));

        // Replace the inner state, dropping the previous socket's
        // closures (JS has already released them because the old
        // WebSocket is closing).
        self.ws_inner.update_value(|b| {
            b.socket = Some(ws);
            b.on_open = Some(on_open);
            b.on_message = Some(on_message);
            b.on_error = Some(on_error);
            b.on_close = Some(on_close);
            b.reconnect = None;
        });
    }

    fn schedule_reconnect(&self, attempt: u32) {
        let delay = std::cmp::min(
            RECONNECT_BASE_MS * 2u32.saturating_pow(attempt.min(5)),
            RECONNECT_MAX_MS,
        );
        let state = *self;
        let timeout = gloo_timers::callback::Timeout::new(delay, move || {
            state.connect(attempt);
        });
        // Store the timeout so that scheduling a new one drops this one
        // (cancelling it). Without this, rapid reconnect cycles would
        // leak pending timers.
        self.ws_inner.update_value(|b| {
            b.socket = None;
            b.reconnect = Some(timeout);
        });
    }
}

fn apply_full_snapshot(
    rooms: EntityMap<RoomSnapshot>,
    plugs: EntityMap<PlugSnapshot>,
    heating: EntityMap<HeatingZoneSnapshot>,
    lights: EntityMap<LightSnapshot>,
    room_names: RwSignal<Vec<String>>,
    plug_names: RwSignal<Vec<String>>,
    heating_names: RwSignal<Vec<String>>,
    light_names: RwSignal<Vec<String>>,
    snap: FullStateSnapshot,
) {
    sync_map(rooms, room_names, snap.rooms, |r| r.name.clone());
    sync_map(plugs, plug_names, snap.plugs, |p| p.device.clone());
    sync_map(heating, heating_names, snap.heating_zones, |z| z.name.clone());
    sync_map(lights, light_names, snap.lights, |l| l.device.clone());
}

/// Diff a full list into the per-entity map: update existing signals,
/// insert new ones, drop removed ones, and re-publish the ordered name
/// list so the top-level `<For>` picks up the change.
fn sync_map<T>(
    map: EntityMap<T>,
    names: RwSignal<Vec<String>>,
    items: Vec<T>,
    key_of: impl Fn(&T) -> String,
) where
    T: Clone + PartialEq + Send + Sync + 'static,
{
    let new_keys: Vec<String> = items.iter().map(&key_of).collect();
    let new_set: BTreeSet<String> = new_keys.iter().cloned().collect();

    let mut added = false;
    let mut removed = false;
    map.update_value(|b| {
        let to_remove: Vec<String> = b
            .keys()
            .filter(|k| !new_set.contains(k.as_str()))
            .cloned()
            .collect();
        for k in to_remove {
            b.remove(&k);
            removed = true;
        }
        for item in items {
            let key = key_of(&item);
            if let Some(sig) = b.get(&key).copied() {
                sig.set(item);
            } else {
                b.insert(key, RwSignal::new(item));
                added = true;
            }
        }
    });
    let current = names.get_untracked();
    if added || removed || current != new_keys {
        names.set(new_keys);
    }
}

fn upsert_entity<T>(
    map: EntityMap<T>,
    names: RwSignal<Vec<String>>,
    key: String,
    item: T,
) where
    T: Clone + PartialEq + Send + Sync + 'static,
{
    let mut is_new = false;
    map.update_value(|b| {
        if let Some(sig) = b.get(&key).copied() {
            sig.set(item);
        } else {
            b.insert(key.clone(), RwSignal::new(item));
            is_new = true;
        }
    });
    if is_new {
        names.update(|list| {
            if !list.iter().any(|n| n == &key) {
                list.push(key);
                list.sort();
            }
        });
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
