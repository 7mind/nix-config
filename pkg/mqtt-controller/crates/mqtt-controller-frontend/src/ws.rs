//! WebSocket connection manager + per-entity reactive signals.
//!
//! This module implements the reliability + visibility contract from
//! the `resilient-ws-ui` skill:
//!
//! - Per-connection four-state machine (NEW → ALIVE → STALE → DEAD)
//!   with a STALE grace period that enables overlapping-connection
//!   failover.
//! - Application-level heartbeat with per-ping nonces and per-ping
//!   timeouts (`ClientMessage::Ping` / `ServerMessage::Pong`). Each
//!   exchange has its own deadline; "any message in the last N seconds"
//!   is not enough, because the *specific channel* may be stuck while
//!   broadcasts keep flowing.
//! - Pool of up to [`MAX_LIVE_CONNECTIONS`] concurrent WebSockets. When
//!   the active connection goes STALE we open a replacement
//!   immediately and let the old one run through its grace period;
//!   whichever pongs first wins.
//! - Exponential backoff with **full jitter**, cap, max attempts, and
//!   a terminal state when the budget is exhausted. The attempt
//!   counter resets to 0 the moment any connection reaches ALIVE.
//! - Close-code classification: 1002/1003/1007/1009/1010/1015 stop
//!   trying so we don't loop forever on a protocol bug.
//! - Time-jump detector: a 1 Hz timer that compares wall-clock elapsed
//!   to its expected period and, on a long gap, triggers a proactive
//!   replacement (NAT/TCP state is gone after a freeze).
//! - Page Lifecycle wiring: visibilitychange, pageshow/pagehide,
//!   online/offline. Reconnects are deferred while the tab is hidden.
//! - `destroyed` flag guarding every state handler / scheduler so a
//!   teardown can't re-arm timers as a side effect.
//! - Bounded WS event log, RTT windows (30s / 1m / 5m), packet-loss
//!   accounting — all surfaced through the [`ManagerStats`] signal so
//!   the indicator widget can render them.

use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};

use gloo_timers::callback::{Interval, Timeout};
use leptos::prelude::*;
use leptos::reactive::owner::LocalStorage;
use wasm_bindgen::prelude::*;
use wasm_bindgen::JsCast;
use web_sys::{CloseEvent, ErrorEvent, MessageEvent, WebSocket};

use mqtt_controller_wire::{
    ClientMessage, DecisionLogEntry, EntityUpdate, FullStateSnapshot, HeatingZoneSnapshot,
    LightSnapshot, LogEntryDto, PlugSnapshot, RoomSnapshot, ServerMessage, TopologyInfo,
};

// ---------------------------------------------------------------------------
// Tuning — all timing constants live here so a reviewer can find them.
// ---------------------------------------------------------------------------

const MAX_LOG_ENTRIES: usize = 200;

/// Hard cap on the number of WebSocket objects we keep alive at once.
/// During STALE-grace failover the pool must hold at least the old +
/// the replacement (= 2). A cap of 3 leaves headroom for a second
/// supersede if the replacement also goes STALE, without unbounded
/// forking on a bug loop.
const MAX_LIVE_CONNECTIONS: usize = 3;

/// Max wait for the OPEN event after `new WebSocket(...)`. After this
/// we abort the connection and treat it as failed. A hanging handshake
/// is the captive-portal / SYN-blackhole case the platform will not
/// time out for us on a useful timescale.
pub const CONNECT_TIMEOUT_MS: u32 = 10_000;

/// Cadence of the client application heartbeat. Must be comfortably
/// under known intermediary idle timeouts (cellular NAT ~30s, Cloudflare
/// 100s, Nginx 60s) so the channel never goes idle from the carrier's
/// point of view.
const PING_INTERVAL_MS: u32 = 15_000;

/// Per-ping deadline. If no matching `Pong` arrives within this window,
/// the connection transitions ALIVE → STALE.
pub const PONG_TIMEOUT_MS: u32 = 5_000;

/// How long a STALE connection has to recover (a late `Pong` arrives,
/// or any other server message lands on the same socket) before we
/// declare it DEAD. A replacement is opened the moment we enter STALE,
/// so this is purely a "second chance" budget for the old socket.
pub const STALE_GRACE_PERIOD_MS: u32 = 8_000;

/// Backoff: base × 2^attempt, then min'd with cap, then **multiplied by
/// random(0.5, 1.0)** for full jitter. After [`RECONNECT_MAX_ATTEMPTS`]
/// failures the manager enters its terminal state.
const RECONNECT_BASE_MS: u32 = 1_000;
const RECONNECT_MAX_MS: u32 = 30_000;
const RECONNECT_MAX_ATTEMPTS: u32 = 15;

/// Time-jump detector cadence and threshold.
const TICK_INTERVAL_MS: u32 = 1_000;
const TIME_JUMP_THRESHOLD_MS: i64 = 2_000;

/// 10 Hz repaint tick for countdown animations in the indicator.
const REPAINT_INTERVAL_MS: u32 = 100;

/// RFC 6455 close codes that indicate a permanent failure mode — there
/// is no point reconnecting, the next socket will hit the same bug.
const NON_RETRIABLE_CODES: &[u16] = &[
    1002, // Protocol Error
    1003, // Unsupported Data
    1007, // Invalid Payload
    1009, // Message Too Big
    1010, // Mandatory Extension
    1015, // TLS Failure
];

/// RTT window edges, in seconds. Each window is rendered separately so
/// the user can tell a short-term spike from a sustained regression.
const RTT_WINDOW_30S: u64 = 30;
const RTT_WINDOW_1M: u64 = 60;
const RTT_WINDOW_5M: u64 = 300;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Per-connection state machine. STALE is a first-class state, not a
/// transient moment inside ALIVE → DEAD: it has its own grace period
/// during which we keep the old socket alongside the replacement.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConnState {
    /// Handshake in progress (connect timeout armed).
    New,
    /// Open + recent matching pong.
    Alive,
    /// Heartbeat timed out. May recover within [`STALE_GRACE_PERIOD_MS`].
    Stale,
    /// Terminal. Kept briefly visible in the indicator, then evicted.
    Dead,
}

impl ConnState {
    pub fn label(&self) -> &'static str {
        match self {
            ConnState::New => "NEW",
            ConnState::Alive => "ALIVE",
            ConnState::Stale => "STALE",
            ConnState::Dead => "DEAD",
        }
    }
}

/// Derived widget state for the indicator. Composed from the pool of
/// per-connection states + manager-level flags (terminal, deferred).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum WidgetState {
    Alive,
    Stale,
    Connecting,
    #[default]
    Dead,
    Terminal,
    /// A reconnect is scheduled but waiting for the tab to become
    /// visible. Distinct from `Connecting` so the indicator doesn't
    /// lie ("retrying") while it is actually idle.
    Deferred,
}

impl WidgetState {
    pub fn label(&self) -> &'static str {
        match self {
            WidgetState::Alive => "alive",
            WidgetState::Stale => "stale",
            WidgetState::Connecting => "connecting",
            WidgetState::Dead => "dead",
            WidgetState::Terminal => "stopped",
            WidgetState::Deferred => "deferred",
        }
    }
}

/// Snapshot view of one connection in the pool, for the tooltip.
#[derive(Clone, Debug, PartialEq)]
pub struct ConnectionStats {
    pub id: u64,
    pub state: ConnState,
    pub state_since_ms: i64,
    pub uptime_ms: i64,
    pub in_flight_pings: usize,
    pub last_rtt_ms: Option<u64>,
    pub is_active: bool,
}

/// Both endpoints of a scheduled reconnect.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ReconnectScheduled {
    pub started_at_ms: i64,
    pub fires_at_ms: i64,
}

/// Aggregated RTT bucket for one time window (e.g. the last 30s).
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct RttWindow {
    pub count: usize,
    pub min_ms: Option<u64>,
    pub median_ms: Option<u64>,
    pub max_ms: Option<u64>,
}

/// One row in the bounded WS event log surfaced through [`ManagerStats`].
#[derive(Clone, Debug, PartialEq)]
pub struct WsEvent {
    pub ts_ms: i64,
    pub line: String,
}

/// Aggregated view used by the indicator. Updated atomically as a unit
/// so the UI sees a consistent snapshot.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct ManagerStats {
    pub connections: Vec<ConnectionStats>,
    pub active_id: Option<u64>,
    /// Reconnect is scheduled. Both endpoints (started_at / fires_at)
    /// are exposed so the indicator can render the ring as `(fires -
    /// now) / (fires - started)`.
    pub reconnect_scheduled: Option<ReconnectScheduled>,
    /// Reconnect is waiting for `visibilitychange` → visible.
    pub reconnect_deferred_until_visible: bool,
    /// Attempts consumed in the current outage. Resets on ALIVE.
    pub backoff_attempt: u32,
    pub backoff_max: u32,
    /// Manager has stopped trying — either permanent close code or
    /// max attempts hit. Surfaced to the indicator as "stopped".
    pub is_terminal: bool,
    /// Last RFC 6455 close code seen, for the tooltip diagnostic line.
    pub last_close_code: Option<u16>,
    pub last_close_reason: Option<String>,
    pub rtt_30s: RttWindow,
    pub rtt_1m: RttWindow,
    pub rtt_5m: RttWindow,
    /// Pings sent minus pongs received as a percentage of sent. Tracked
    /// across the lifetime of the manager (resets only when the user
    /// reloads the page).
    pub pings_sent: u64,
    pub pongs_received: u64,
    pub events: VecDeque<WsEvent>,
    /// Current widget state, derived from the pool + flags above.
    pub widget: WidgetState,
}

// ---------------------------------------------------------------------------
// Domain (entity) types — unchanged from the original ws.rs
// ---------------------------------------------------------------------------

/// One JSON popup request: title and pretty-printed body.
#[derive(Clone, Debug, PartialEq)]
pub struct JsonPopup {
    pub title: String,
    pub json: String,
}

/// Per-entity persisted decision-log page. Built up as paginated
/// responses arrive from the server; the popup reads it reactively.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct EntityLogPage {
    pub entries: Vec<LogEntryDto>,
    pub has_more: bool,
    pub loading: bool,
    pub loaded: bool,
}

/// Arena-stored map of per-entity signals. LocalStorage lets us store
/// the BTreeMap (which holds signals that hand out shared ownership)
/// without requiring the map itself to be `Send + Sync` — `StoredValue`
/// itself is `Send + Sync` because it's just an arena key.
pub type EntityMap<T> = StoredValue<BTreeMap<String, RwSignal<T>>, LocalStorage>;

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

/// Held WebSocket resources for one pool entry. The `Closure` handles
/// stay alive for the lifetime of the connection record so JS can fire
/// them; dropping the record releases them.
struct ConnRecord {
    id: u64,
    socket: WebSocket,
    state: ConnState,
    state_since_ms: i64,
    opened_at_ms: Option<i64>,
    /// Outstanding pings keyed by nonce. Value is the client_ts_ms we
    /// sent so we can compute RTT on the matching Pong.
    pending_pings: HashMap<String, i64>,
    /// Most recent RTT measured for this connection (display only).
    last_rtt_ms: Option<u64>,
    /// True once this connection has been promoted as active — we then
    /// route outbound `send()` through it.
    is_active: bool,
    /// Set when a newer connection has taken over; we keep this one
    /// open just long enough for any in-flight pong to land.
    superseded: bool,
    // Held closure handles — released on drop.
    _on_open: Closure<dyn Fn()>,
    _on_message: Closure<dyn Fn(MessageEvent)>,
    _on_error: Closure<dyn Fn(ErrorEvent)>,
    _on_close: Closure<dyn Fn(CloseEvent)>,
    // Per-connection timers.
    connect_timeout: Option<Timeout>,
    ping_interval: Option<Interval>,
    /// Pong-timeout for the most-recently-sent ping. We do not arm one
    /// per outstanding nonce; the worst-case RTT we care about is the
    /// most recent one, and per-ping timers would multiply when the
    /// channel briefly stalls.
    pong_timeout: Option<Timeout>,
    stale_grace: Option<Timeout>,
}

/// Manager-wide state. Lives inside a `StoredValue<_, LocalStorage>` so
/// every closure can reach it through a `Copy` handle.
struct ManagerInner {
    connections: BTreeMap<u64, ConnRecord>,
    next_id: u64,
    active_id: Option<u64>,
    backoff_attempt: u32,
    is_terminal: bool,
    last_close_code: Option<u16>,
    last_close_reason: Option<String>,
    reconnect_timeout: Option<Timeout>,
    reconnect_scheduled: Option<ReconnectScheduled>,
    reconnect_deferred_until_visible: bool,
    /// 1 Hz tick driving the time-jump detector. Also re-asserts the
    /// stats signal so uptime / state-since strings stay live without
    /// any other event firing.
    tick_interval: Option<Interval>,
    /// Wall-clock millis at the most recent tick. Compared against the
    /// expected period to detect freeze/suspend.
    last_tick_at_ms: i64,
    /// 10 Hz repaint tick driving countdown animations in the indicator.
    repaint_interval: Option<Interval>,
    destroyed: bool,
    events: VecDeque<WsEvent>,
    /// Lifetime RTT samples (timestamp_ms, rtt_ms). Trimmed to the
    /// 5-minute window on every push.
    rtt_samples: VecDeque<(i64, u64)>,
    pings_sent: u64,
    pongs_received: u64,
    /// Held JS event-listener closures. Released on drop, which fires
    /// when the manager itself is dropped — i.e. effectively never for
    /// a long-lived CSR page, but keeps things tidy under tests.
    _lifecycle_listeners: Vec<LifecycleListener>,
}

struct LifecycleListener {
    target: web_sys::EventTarget,
    event: &'static str,
    closure: Closure<dyn Fn(web_sys::Event)>,
}

impl Drop for LifecycleListener {
    fn drop(&mut self) {
        let _ = self.target.remove_event_listener_with_callback(
            self.event,
            self.closure.as_ref().unchecked_ref(),
        );
    }
}

// ---------------------------------------------------------------------------
// WsState — public façade. Same surface as before plus the new
// `stats` / `now_ms` signals consumed by the indicator.
// ---------------------------------------------------------------------------

/// Reactive WebSocket state available to all components.
///
/// `Copy` because every field is either a `Signal` (already `Copy`) or
/// a `StoredValue` (ditto). Cheap to pass through closures.
#[derive(Clone, Copy)]
pub struct WsState {
    pub topology: ReadSignal<Option<TopologyInfo>>,

    pub room_names: RwSignal<Vec<String>>,
    pub plug_names: RwSignal<Vec<String>>,
    pub heating_names: RwSignal<Vec<String>>,
    pub light_names: RwSignal<Vec<String>>,

    pub log_entries: ReadSignal<Vec<DecisionLogEntry>>,
    pub filter_entities: ReadSignal<BTreeSet<String>>,
    pub set_filter_entities: WriteSignal<BTreeSet<String>>,

    pub json_popup: RwSignal<Option<JsonPopup>>,
    pub log_popup_entity: RwSignal<Option<String>>,

    /// Monotonic counter ticking once per second. Components that
    /// display per-entity countdowns subscribe to this; the connection
    /// indicator uses [`Self::now_ms`] for its smoother 10 Hz refresh.
    pub tick_seq: ReadSignal<u64>,

    /// Wall-clock millis updated at the repaint cadence
    /// ([`REPAINT_INTERVAL_MS`]). Drives countdown rings.
    pub now_ms: ReadSignal<i64>,

    /// Aggregated connection-health view. Updated atomically on every
    /// state change.
    pub stats: ReadSignal<ManagerStats>,

    // --- internals (private to the module — accessed via methods) ---
    rooms: EntityMap<RoomSnapshot>,
    plugs: EntityMap<PlugSnapshot>,
    heating: EntityMap<HeatingZoneSnapshot>,
    lights: EntityMap<LightSnapshot>,
    entity_logs: StoredValue<BTreeMap<String, RwSignal<EntityLogPage>>, LocalStorage>,

    inner: StoredValue<ManagerInner, LocalStorage>,

    set_topology: WriteSignal<Option<TopologyInfo>>,
    set_log_entries: WriteSignal<Vec<DecisionLogEntry>>,
    set_now_ms: WriteSignal<i64>,
    set_stats: WriteSignal<ManagerStats>,
}

impl WsState {
    pub fn new() -> Self {
        let (topology, set_topology) = signal(None::<TopologyInfo>);
        let (log_entries, set_log_entries) = signal(Vec::<DecisionLogEntry>::new());
        let (filter_entities, set_filter_entities) = signal(BTreeSet::<String>::new());
        let (tick_seq, set_tick_seq) = signal(0u64);
        let (now_ms, set_now_ms) = signal(wall_now_ms());
        let (stats, set_stats) = signal(ManagerStats::default());

        let inner = ManagerInner {
            connections: BTreeMap::new(),
            next_id: 0,
            active_id: None,
            backoff_attempt: 0,
            is_terminal: false,
            last_close_code: None,
            last_close_reason: None,
            reconnect_timeout: None,
            reconnect_scheduled: None,
            reconnect_deferred_until_visible: false,
            tick_interval: None,
            last_tick_at_ms: wall_now_ms(),
            repaint_interval: None,
            destroyed: false,
            events: VecDeque::new(),
            rtt_samples: VecDeque::new(),
            pings_sent: 0,
            pongs_received: 0,
            _lifecycle_listeners: Vec::new(),
        };

        let state = Self {
            topology,
            room_names: RwSignal::new(Vec::new()),
            plug_names: RwSignal::new(Vec::new()),
            heating_names: RwSignal::new(Vec::new()),
            light_names: RwSignal::new(Vec::new()),
            log_entries,
            filter_entities,
            set_filter_entities,
            json_popup: RwSignal::new(None),
            log_popup_entity: RwSignal::new(None),
            tick_seq,
            now_ms,
            stats,
            rooms: StoredValue::new_local(BTreeMap::new()),
            plugs: StoredValue::new_local(BTreeMap::new()),
            heating: StoredValue::new_local(BTreeMap::new()),
            lights: StoredValue::new_local(BTreeMap::new()),
            entity_logs: StoredValue::new_local(BTreeMap::new()),
            inner: StoredValue::new_local(inner),
            set_topology,
            set_log_entries,
            set_now_ms,
            set_stats,
        };

        // Start the 1 Hz domain tick (powers entity-card countdowns).
        let tick = Interval::new(TICK_INTERVAL_MS, move || {
            set_tick_seq.update(|n| *n = n.wrapping_add(1));
        });
        tick.forget();

        // Start the 10 Hz repaint tick + the time-jump detector.
        let st = state;
        let repaint = Interval::new(REPAINT_INTERVAL_MS, move || {
            st.set_now_ms.set(wall_now_ms());
        });
        let st2 = state;
        let time_jump = Interval::new(TICK_INTERVAL_MS, move || {
            st2.inner.update_value(|m| handle_time_tick(m, st2));
        });
        state.inner.update_value(|m| {
            m.repaint_interval = Some(repaint);
            m.tick_interval = Some(time_jump);
        });

        // Wire page-lifecycle listeners. Each handler immediately calls
        // back into the manager so the rules below describe behaviour,
        // not policy spread across files.
        install_lifecycle_listeners(state);

        // First connection.
        state.inner.update_value(|m| {
            ensure_replacement(m, state);
        });
        // Initial stats publish so the indicator renders on first paint.
        publish_stats(state);

        state
    }

    // -- Domain accessors (unchanged) ----------------------------------

    pub fn room_signal(&self, name: &str) -> Option<RwSignal<RoomSnapshot>> {
        self.rooms.with_value(|m| m.get(name).copied())
    }
    pub fn plug_signal(&self, name: &str) -> Option<RwSignal<PlugSnapshot>> {
        self.plugs.with_value(|m| m.get(name).copied())
    }
    pub fn heating_signal(&self, name: &str) -> Option<RwSignal<HeatingZoneSnapshot>> {
        self.heating.with_value(|m| m.get(name).copied())
    }
    pub fn light_signal(&self, device: &str) -> Option<RwSignal<LightSnapshot>> {
        self.lights.with_value(|m| m.get(device).copied())
    }
    pub fn clear_log(&self) {
        self.set_log_entries.set(Vec::new());
    }
    pub fn toggle_filter(&self, entity: &str) {
        self.set_filter_entities.update(|set| {
            if !set.remove(entity) {
                set.insert(entity.to_string());
            }
        });
    }
    pub fn show_json(&self, title: String, json: String) {
        self.json_popup.set(Some(JsonPopup { title, json }));
    }
    pub fn hide_json(&self) {
        self.json_popup.set(None);
    }
    pub fn entity_log_signal(&self, entity: &str) -> RwSignal<EntityLogPage> {
        if let Some(sig) = self.entity_logs.with_value(|m| m.get(entity).copied()) {
            return sig;
        }
        let sig = RwSignal::new(EntityLogPage::default());
        self.entity_logs.update_value(|m| {
            m.entry(entity.to_string()).or_insert(sig);
        });
        sig
    }
    pub fn open_log_popup(&self, entity: String) {
        let sig = self.entity_log_signal(&entity);
        sig.update(|page| {
            *page = EntityLogPage {
                entries: Vec::new(),
                has_more: false,
                loading: true,
                loaded: false,
            };
        });
        self.send(&ClientMessage::GetEntityLog {
            entity: entity.clone(),
            before_ts_ms: None,
            limit: None,
        });
        self.log_popup_entity.set(Some(entity));
    }
    pub fn close_log_popup(&self) {
        self.log_popup_entity.set(None);
    }
    pub fn load_more_log(&self, entity: &str) {
        let sig = self.entity_log_signal(entity);
        let cursor = sig.with_untracked(|page| {
            if page.loading || !page.has_more {
                return None;
            }
            page.entries.last().map(|e| e.timestamp_epoch_ms)
        });
        let Some(before) = cursor else { return };
        sig.update(|page| page.loading = true);
        self.send(&ClientMessage::GetEntityLog {
            entity: entity.to_string(),
            before_ts_ms: Some(before),
            limit: None,
        });
    }

    /// Send a client message through the active connection (if any).
    /// Falls back silently when no connection is ALIVE; the caller's
    /// state will resync on the next `StateSnapshot` after reconnect.
    pub fn send(&self, msg: &ClientMessage) {
        let socket = self.inner.with_value(|m| {
            let id = m.active_id?;
            let rec = m.connections.get(&id)?;
            if rec.state != ConnState::Alive {
                return None;
            }
            Some(rec.socket.clone())
        });
        let Some(ws) = socket else { return };
        if ws.ready_state() == WebSocket::OPEN {
            if let Ok(json) = serde_json::to_string(msg) {
                let _ = ws.send_with_str(&json);
            }
        }
    }

    /// Manual retry from the indicator. Clears the terminal flag and
    /// resets the attempt counter so backoff starts fresh.
    pub fn manual_retry(&self) {
        self.inner.update_value(|m| {
            if m.destroyed {
                return;
            }
            m.is_terminal = false;
            m.backoff_attempt = 0;
            m.reconnect_deferred_until_visible = false;
            if let Some(t) = m.reconnect_timeout.take() {
                t.cancel();
            }
            m.reconnect_scheduled = None;
            log_event(m, "manual retry");
        });
        self.inner.update_value(|m| {
            ensure_replacement(m, *self);
        });
        publish_stats(*self);
    }
}

// ---------------------------------------------------------------------------
// Connection lifecycle
// ---------------------------------------------------------------------------

/// Allocate a fresh connection id, open a WebSocket, and install all
/// per-socket closures + the connect-timeout watchdog. The connection
/// starts in NEW; transition to ALIVE happens in the on_open closure.
///
/// Returns the new id on success. Returns `None` if the constructor
/// failed (e.g. an invalid URL); the caller is expected to schedule a
/// reconnect in that case.
fn ensure_replacement(m: &mut ManagerInner, state: WsState) -> Option<u64> {
    if m.destroyed || m.is_terminal {
        return None;
    }
    // Don't spawn if the pool already has a non-DEAD connection that
    // could still recover; we'd just fork unnecessarily. The two
    // legitimate triggers — STALE and the initial connect — call this
    // function after explicit checks.
    if has_open_replacement(m) {
        return None;
    }
    if m.connections.len() >= MAX_LIVE_CONNECTIONS {
        // Pool full. Evict the oldest DEAD entry to make room. If
        // there is no DEAD entry, refuse — better to wait one cycle
        // than to fork unboundedly.
        let oldest_dead = m
            .connections
            .iter()
            .filter(|(_, r)| r.state == ConnState::Dead)
            .min_by_key(|(_, r)| r.state_since_ms)
            .map(|(id, _)| *id);
        match oldest_dead {
            Some(id) => evict(m, id),
            None => return None,
        }
    }

    let url = build_ws_url();
    let ws = match WebSocket::new(&url) {
        Ok(ws) => ws,
        Err(_) => {
            log_event(m, &format!("WebSocket::new failed for {url}"));
            schedule_reconnect(m, state);
            return None;
        }
    };
    ws.set_binary_type(web_sys::BinaryType::Arraybuffer);

    let id = m.next_id;
    m.next_id = m.next_id.saturating_add(1);

    // Closures keep a `Copy` handle to the manager + the connection
    // id; on fire they look the record up by id. If it's gone, they're
    // no-ops (the connection was evicted out from under them).
    let st = state;
    let on_open_id = id;
    let on_open = Closure::<dyn Fn()>::new(move || {
        st.inner.update_value(|m| handle_open(m, st, on_open_id));
        publish_stats(st);
    });
    ws.set_onopen(Some(on_open.as_ref().unchecked_ref()));

    let st = state;
    let on_msg_id = id;
    let on_message = Closure::<dyn Fn(MessageEvent)>::new(move |e: MessageEvent| {
        let Ok(text) = e.data().dyn_into::<js_sys::JsString>() else {
            return;
        };
        let s: String = text.into();
        let Ok(msg) = serde_json::from_str::<ServerMessage>(&s) else {
            return;
        };
        st.inner.update_value(|m| handle_message(m, st, on_msg_id, &msg));
        // Domain messages mutate per-entity signals outside the
        // manager state, so do that after releasing the borrow.
        apply_domain_message(st, msg);
        publish_stats(st);
    });
    ws.set_onmessage(Some(on_message.as_ref().unchecked_ref()));

    let st = state;
    let on_err_id = id;
    let on_error = Closure::<dyn Fn(ErrorEvent)>::new(move |_e: ErrorEvent| {
        st.inner.update_value(|m| {
            log_event(m, &format!("conn #{on_err_id} error event"));
        });
        publish_stats(st);
    });
    ws.set_onerror(Some(on_error.as_ref().unchecked_ref()));

    let st = state;
    let on_close_id = id;
    let on_close = Closure::<dyn Fn(CloseEvent)>::new(move |e: CloseEvent| {
        let code = e.code();
        let reason = e.reason();
        let was_clean = e.was_clean();
        st.inner
            .update_value(|m| handle_close(m, st, on_close_id, code, reason, was_clean));
        publish_stats(st);
    });
    ws.set_onclose(Some(on_close.as_ref().unchecked_ref()));

    // Connect-timeout watchdog. We arm it here, then cancel in on_open.
    // The cross-check on native readyState guards against racing the
    // platform's OPEN event with our timeout.
    let st = state;
    let timeout_id = id;
    let connect_timeout = Timeout::new(CONNECT_TIMEOUT_MS, move || {
        st.inner.update_value(|m| {
            // Sample read-only state, drop the borrow, then close + log.
            let should_fire = m
                .connections
                .get(&timeout_id)
                .map(|rec| {
                    rec.state == ConnState::New
                        && rec.socket.ready_state() == WebSocket::CONNECTING
                })
                .unwrap_or(false);
            if !should_fire {
                return;
            }
            if let Some(rec) = m.connections.get(&timeout_id) {
                let _ = rec.socket.close();
            }
            log_event(
                m,
                &format!("conn #{timeout_id} connect timeout after {CONNECT_TIMEOUT_MS}ms"),
            );
            // Treat as a synthetic close so we drive backoff + DEAD
            // transitions through the normal path.
            handle_close(m, st, timeout_id, 4001, "connect timeout".into(), false);
        });
        publish_stats(st);
    });

    let now = wall_now_ms();
    let rec = ConnRecord {
        id,
        socket: ws,
        state: ConnState::New,
        state_since_ms: now,
        opened_at_ms: None,
        pending_pings: HashMap::new(),
        last_rtt_ms: None,
        is_active: false,
        superseded: false,
        _on_open: on_open,
        _on_message: on_message,
        _on_error: on_error,
        _on_close: on_close,
        connect_timeout: Some(connect_timeout),
        ping_interval: None,
        pong_timeout: None,
        stale_grace: None,
    };
    m.connections.insert(id, rec);
    log_event(m, &format!("conn #{id} opening to {url}"));
    Some(id)
}

fn has_open_replacement(m: &ManagerInner) -> bool {
    m.connections
        .values()
        .any(|r| matches!(r.state, ConnState::New | ConnState::Alive) && !r.superseded)
}

fn evict(m: &mut ManagerInner, id: u64) {
    if let Some(rec) = m.connections.remove(&id) {
        log_event(m, &format!("conn #{id} evicted (state {})", rec.state.label()));
    }
    if m.active_id == Some(id) {
        m.active_id = None;
    }
}

/// `on_open` handler. Transition NEW → ALIVE, cancel connect timeout,
/// arm the heartbeat, promote to active if there is no current active.
fn handle_open(m: &mut ManagerInner, state: WsState, id: u64) {
    if m.destroyed {
        return;
    }
    let Some(rec) = m.connections.get_mut(&id) else {
        return;
    };
    rec.state = ConnState::Alive;
    rec.state_since_ms = wall_now_ms();
    rec.opened_at_ms = Some(rec.state_since_ms);
    if let Some(t) = rec.connect_timeout.take() {
        t.cancel();
    }

    // Reset backoff — any ALIVE connection in the pool means our
    // reconnect budget is fresh.
    m.backoff_attempt = 0;
    m.is_terminal = false;
    if let Some(t) = m.reconnect_timeout.take() {
        t.cancel();
    }
    m.reconnect_scheduled = None;
    m.reconnect_deferred_until_visible = false;

    log_event(m, &format!("conn #{id} ALIVE"));

    // Promote: if there's no active connection, this one becomes
    // active. If there is one and it's STALE, supersede it.
    promote_if_better(m, id);
    arm_heartbeat(m, state, id);
    send_initial_requests(m, id);
}

fn promote_if_better(m: &mut ManagerInner, new_id: u64) {
    let promote = match m.active_id {
        None => true,
        Some(cur) => {
            let cur_state = m
                .connections
                .get(&cur)
                .map(|r| r.state)
                .unwrap_or(ConnState::Dead);
            matches!(cur_state, ConnState::Stale | ConnState::Dead)
        }
    };
    if promote {
        let prev = m.active_id;
        if let Some(prev_id) = prev {
            if let Some(rec) = m.connections.get_mut(&prev_id) {
                rec.is_active = false;
                rec.superseded = true;
                // Close the superseded socket — its replacement is
                // already ALIVE.
                let _ = rec.socket.close_with_code_and_reason(1000, "superseded");
            }
            log_event(m, &format!("conn #{prev_id} superseded by #{new_id}"));
        }
        if let Some(rec) = m.connections.get_mut(&new_id) {
            rec.is_active = true;
        }
        m.active_id = Some(new_id);
    }
}

fn send_initial_requests(m: &mut ManagerInner, id: u64) {
    let Some(rec) = m.connections.get(&id) else {
        return;
    };
    if rec.socket.ready_state() != WebSocket::OPEN {
        return;
    }
    let snap = ClientMessage::GetState;
    let topo = ClientMessage::GetTopology;
    if let Ok(s) = serde_json::to_string(&snap) {
        let _ = rec.socket.send_with_str(&s);
    }
    if let Ok(s) = serde_json::to_string(&topo) {
        let _ = rec.socket.send_with_str(&s);
    }
}

fn arm_heartbeat(m: &mut ManagerInner, state: WsState, id: u64) {
    let st = state;
    let ping_id = id;
    let interval = Interval::new(PING_INTERVAL_MS, move || {
        st.inner.update_value(|m| send_ping(m, st, ping_id));
        publish_stats(st);
    });
    if let Some(rec) = m.connections.get_mut(&id) {
        rec.ping_interval = Some(interval);
    }
    // Fire the first ping immediately so we get a fast RTT sample and
    // a fast detection of an already-dead connection. The Interval
    // itself fires on its first deadline, not immediately.
    send_ping(m, state, id);
}

fn send_ping(m: &mut ManagerInner, state: WsState, id: u64) {
    if m.destroyed {
        return;
    }
    let now = wall_now_ms();
    let nonce = make_nonce();
    let msg = ClientMessage::Ping {
        nonce: nonce.clone(),
        client_ts_ms: now,
    };
    let Some(rec) = m.connections.get_mut(&id) else {
        return;
    };
    if rec.state != ConnState::Alive {
        return;
    }
    if rec.socket.ready_state() != WebSocket::OPEN {
        return;
    }
    if let Ok(s) = serde_json::to_string(&msg) {
        if rec.socket.send_with_str(&s).is_ok() {
            rec.pending_pings.insert(nonce, now);
            m.pings_sent = m.pings_sent.saturating_add(1);
        }
    }

    // Arm a single pong-timeout per connection. If one is already
    // armed (we're spamming pings while a pong is outstanding),
    // leave it — the existing deadline still covers liveness.
    if rec.pong_timeout.is_none() {
        let st = state;
        let to_id = id;
        let to = Timeout::new(PONG_TIMEOUT_MS, move || {
            st.inner.update_value(|m| handle_pong_timeout(m, st, to_id));
            publish_stats(st);
        });
        rec.pong_timeout = Some(to);
    }
}

fn handle_pong_timeout(m: &mut ManagerInner, state: WsState, id: u64) {
    if m.destroyed {
        return;
    }
    let still_pending = m
        .connections
        .get(&id)
        .map(|r| !r.pending_pings.is_empty())
        .unwrap_or(false);
    if !still_pending {
        // A late pong already cleared the queue — nothing to do.
        if let Some(rec) = m.connections.get_mut(&id) {
            rec.pong_timeout = None;
        }
        return;
    }
    transition_to_stale(m, state, id, "pong timeout");
}

fn transition_to_stale(m: &mut ManagerInner, state: WsState, id: u64, reason: &str) {
    let Some(rec) = m.connections.get_mut(&id) else {
        return;
    };
    if !matches!(rec.state, ConnState::Alive | ConnState::New) {
        return;
    }
    rec.state = ConnState::Stale;
    rec.state_since_ms = wall_now_ms();
    if let Some(t) = rec.pong_timeout.take() {
        t.cancel();
    }
    let st = state;
    let grace_id = id;
    rec.stale_grace = Some(Timeout::new(STALE_GRACE_PERIOD_MS, move || {
        st.inner.update_value(|m| {
            transition_to_dead(m, st, grace_id, 4002, "stale grace expired".into(), false);
        });
        publish_stats(st);
    }));
    log_event(m, &format!("conn #{id} STALE ({reason})"));
    // Kick off a replacement immediately. Overlapping failover is the
    // skill's biggest perceived-reliability win.
    ensure_replacement(m, state);
}

fn handle_close(
    m: &mut ManagerInner,
    state: WsState,
    id: u64,
    code: u16,
    reason: String,
    was_clean: bool,
) {
    if m.destroyed {
        return;
    }
    m.last_close_code = Some(code);
    m.last_close_reason = if reason.is_empty() {
        None
    } else {
        Some(reason.clone())
    };
    log_event(
        m,
        &format!(
            "conn #{id} closed code={code} clean={was_clean} reason={}",
            if reason.is_empty() { "-" } else { reason.as_str() }
        ),
    );
    transition_to_dead(m, state, id, code, reason, was_clean);
}

fn transition_to_dead(
    m: &mut ManagerInner,
    state: WsState,
    id: u64,
    code: u16,
    _reason: String,
    _was_clean: bool,
) {
    let was_active = m.active_id == Some(id);
    let was_superseded = m
        .connections
        .get(&id)
        .map(|r| r.superseded)
        .unwrap_or(false);
    if let Some(rec) = m.connections.get_mut(&id) {
        rec.state = ConnState::Dead;
        rec.state_since_ms = wall_now_ms();
        // Stop all per-connection timers; we may keep the record
        // around briefly so the indicator can still show "closed".
        if let Some(t) = rec.connect_timeout.take() {
            t.cancel();
        }
        if let Some(t) = rec.ping_interval.take() {
            t.cancel();
        }
        if let Some(t) = rec.pong_timeout.take() {
            t.cancel();
        }
        if let Some(t) = rec.stale_grace.take() {
            t.cancel();
        }
    }
    if was_active {
        m.active_id = None;
    }

    // Permanent close codes: stop trying. The indicator surfaces this
    // as "stopped" with a manual-retry affordance.
    if NON_RETRIABLE_CODES.contains(&code) {
        m.is_terminal = true;
        log_event(
            m,
            &format!("close code {code} is non-retriable, manager terminal"),
        );
        evict_dead(m);
        return;
    }

    // A superseded close is expected (we closed it ourselves on
    // promotion). Don't drive backoff — the new connection is already
    // active.
    if was_superseded {
        evict_dead(m);
        return;
    }

    evict_dead(m);

    // If any other connection is already New / Alive / Stale, the
    // pool is doing its job — no reconnect needed.
    if has_open_replacement(m) {
        return;
    }

    schedule_reconnect(m, state);
}

fn evict_dead(m: &mut ManagerInner) {
    let ids: Vec<u64> = m
        .connections
        .iter()
        .filter(|(_, r)| r.state == ConnState::Dead)
        .map(|(id, _)| *id)
        .collect();
    for id in ids {
        m.connections.remove(&id);
    }
}

fn handle_message(m: &mut ManagerInner, _state: WsState, id: u64, msg: &ServerMessage) {
    if m.destroyed {
        return;
    }
    if let ServerMessage::Pong {
        nonce,
        client_ts_ms,
        ..
    } = msg
    {
        let now = wall_now_ms();
        // Apply per-connection updates inside the borrow, collect a
        // small report struct, then perform manager-level effects +
        // logging once the `rec` borrow is gone.
        let mut matched_rtt: Option<u64> = None;
        let mut recovered = false;
        if let Some(rec) = m.connections.get_mut(&id) {
            if let Some(sent_at) = rec.pending_pings.remove(nonce) {
                let rtt = (now - sent_at).max(0) as u64;
                rec.last_rtt_ms = Some(rtt);
                matched_rtt = Some(rtt);
            }
            if rec.state == ConnState::Stale {
                rec.state = ConnState::Alive;
                rec.state_since_ms = now;
                if let Some(t) = rec.stale_grace.take() {
                    t.cancel();
                }
                recovered = true;
            }
            if rec.pending_pings.is_empty() {
                if let Some(t) = rec.pong_timeout.take() {
                    t.cancel();
                }
            }
        }
        if let Some(rtt) = matched_rtt {
            m.pongs_received = m.pongs_received.saturating_add(1);
            m.rtt_samples.push_back((now, rtt));
            while let Some(&(t, _)) = m.rtt_samples.front() {
                if now - t > (RTT_WINDOW_5M as i64) * 1000 {
                    m.rtt_samples.pop_front();
                } else {
                    break;
                }
            }
            if rtt > PONG_TIMEOUT_MS as u64 {
                log_event(
                    m,
                    &format!("conn #{id} late pong rtt={rtt}ms (sent {client_ts_ms})"),
                );
            }
        }
        if recovered {
            log_event(m, &format!("conn #{id} ALIVE (recovered from STALE)"));
            m.backoff_attempt = 0;
        }
    }
}

// ---------------------------------------------------------------------------
// Backoff
// ---------------------------------------------------------------------------

fn schedule_reconnect(m: &mut ManagerInner, state: WsState) {
    if m.destroyed || m.is_terminal {
        return;
    }
    if m.reconnect_timeout.is_some() {
        return;
    }
    if m.backoff_attempt >= RECONNECT_MAX_ATTEMPTS {
        m.is_terminal = true;
        log_event(
            m,
            &format!(
                "reconnect budget exhausted after {} attempts, manager terminal",
                m.backoff_attempt
            ),
        );
        return;
    }
    if document_hidden() {
        m.reconnect_deferred_until_visible = true;
        m.reconnect_scheduled = None;
        log_event(m, "reconnect deferred — tab hidden");
        return;
    }
    let delay = backoff_delay_ms(m.backoff_attempt);
    let st = state;
    let to = Timeout::new(delay, move || {
        st.inner.update_value(|m| {
            m.reconnect_timeout = None;
            m.reconnect_scheduled = None;
            m.backoff_attempt = m.backoff_attempt.saturating_add(1);
            log_event(
                m,
                &format!("reconnect attempt #{}", m.backoff_attempt),
            );
            ensure_replacement(m, st);
        });
        publish_stats(st);
    });
    let started = wall_now_ms();
    m.reconnect_timeout = Some(to);
    m.reconnect_scheduled = Some(ReconnectScheduled {
        started_at_ms: started,
        fires_at_ms: started + delay as i64,
    });
    m.reconnect_deferred_until_visible = false;
    log_event(
        m,
        &format!(
            "reconnect in {delay}ms (attempt {} of {})",
            m.backoff_attempt + 1,
            RECONNECT_MAX_ATTEMPTS
        ),
    );
}

/// `base × 2^attempt`, capped, then **full jitter**: multiply by a
/// uniform random in [0.5, 1.0]. Pure base/cap with no jitter causes
/// thundering-herd reconnects after a server restart.
fn backoff_delay_ms(attempt: u32) -> u32 {
    let exp = attempt.min(20);
    let raw = RECONNECT_BASE_MS.saturating_mul(1u32 << exp.min(15));
    let capped = raw.min(RECONNECT_MAX_MS);
    // Full jitter ∈ [0.5, 1.0] × capped. js_sys::Math::random() is the
    // canonical PRNG on wasm32; for backoff it's plenty.
    let factor = 0.5 + 0.5 * js_sys::Math::random();
    ((capped as f64) * factor) as u32
}

// ---------------------------------------------------------------------------
// Time-jump detector
// ---------------------------------------------------------------------------

fn handle_time_tick(m: &mut ManagerInner, state: WsState) {
    if m.destroyed {
        return;
    }
    let now = wall_now_ms();
    let elapsed = now - m.last_tick_at_ms;
    m.last_tick_at_ms = now;
    if elapsed > TICK_INTERVAL_MS as i64 + TIME_JUMP_THRESHOLD_MS {
        // Event-loop or whole platform paused. NAT tables and TCP
        // state may be gone; the OPEN socket won't fire close.
        log_event(
            m,
            &format!(
                "time jump detected ({elapsed}ms elapsed, expected ~{TICK_INTERVAL_MS}ms)"
            ),
        );
        // Long jump → bypass the pong timeout, mark active STALE
        // immediately and open a replacement in parallel.
        if elapsed > PONG_TIMEOUT_MS as i64 {
            if let Some(active) = m.active_id {
                transition_to_stale(m, state, active, "time jump");
            } else {
                ensure_replacement(m, state);
            }
        } else {
            // Short jump — ping existing connections to verify.
            let ids: Vec<u64> = m
                .connections
                .iter()
                .filter(|(_, r)| r.state == ConnState::Alive)
                .map(|(id, _)| *id)
                .collect();
            for id in ids {
                send_ping(m, state, id);
            }
        }
    }
    publish_stats(state);
}

// ---------------------------------------------------------------------------
// Page Lifecycle
// ---------------------------------------------------------------------------

fn install_lifecycle_listeners(state: WsState) {
    let listeners = build_lifecycle_listeners(state);
    state
        .inner
        .update_value(|m| m._lifecycle_listeners = listeners);
}

fn build_lifecycle_listeners(state: WsState) -> Vec<LifecycleListener> {
    let mut out = Vec::new();
    let Some(window) = web_sys::window() else {
        return out;
    };
    let document = window.document();
    let window_target: web_sys::EventTarget = window.clone().into();

    if let Some(doc) = document {
        let target: web_sys::EventTarget = doc.into();
        let st = state;
        let cb = Closure::<dyn Fn(web_sys::Event)>::new(move |_e: web_sys::Event| {
            st.inner.update_value(|m| on_visibility_change(m, st));
            publish_stats(st);
        });
        if target
            .add_event_listener_with_callback("visibilitychange", cb.as_ref().unchecked_ref())
            .is_ok()
        {
            out.push(LifecycleListener {
                target,
                event: "visibilitychange",
                closure: cb,
            });
        }
    }

    for (event, hidden_only) in [
        ("online", false),
        ("offline", false),
        ("pageshow", false),
        ("pagehide", true),
    ] {
        let st = state;
        let ev = event;
        let cb = Closure::<dyn Fn(web_sys::Event)>::new(move |_e: web_sys::Event| {
            st.inner.update_value(|m| on_lifecycle(m, st, ev));
            publish_stats(st);
        });
        let target = window_target.clone();
        if target
            .add_event_listener_with_callback(event, cb.as_ref().unchecked_ref())
            .is_ok()
        {
            out.push(LifecycleListener {
                target,
                event,
                closure: cb,
            });
        }
        let _ = hidden_only; // reserved for future BFCache handling
    }
    out
}

fn on_visibility_change(m: &mut ManagerInner, state: WsState) {
    if document_hidden() {
        log_event(m, "tab hidden");
    } else {
        log_event(m, "tab visible");
        // Run a deferred reconnect, if any.
        if m.reconnect_deferred_until_visible {
            m.reconnect_deferred_until_visible = false;
            schedule_reconnect(m, state);
        }
        // Also poke ALIVE connections to verify they're still alive.
        let ids: Vec<u64> = m
            .connections
            .iter()
            .filter(|(_, r)| r.state == ConnState::Alive)
            .map(|(id, _)| *id)
            .collect();
        for id in ids {
            send_ping(m, state, id);
        }
    }
}

fn on_lifecycle(m: &mut ManagerInner, state: WsState, ev: &'static str) {
    log_event(m, &format!("lifecycle: {ev}"));
    match ev {
        "online" => {
            // Network came back; verify what we have and kick a
            // replacement if nothing is ALIVE.
            let alive_ids: Vec<u64> = m
                .connections
                .iter()
                .filter(|(_, r)| r.state == ConnState::Alive)
                .map(|(id, _)| *id)
                .collect();
            for id in &alive_ids {
                send_ping(m, state, *id);
            }
            if alive_ids.is_empty() {
                ensure_replacement(m, state);
            }
        }
        "offline" => {
            // Network is gone — no point retrying until 'online'.
            if let Some(t) = m.reconnect_timeout.take() {
                t.cancel();
            }
            m.reconnect_scheduled = None;
        }
        "pageshow" => {
            // BFCache restore (or first show). Treat as a likely
            // resume after a long gap.
            if !has_open_replacement(m) {
                ensure_replacement(m, state);
            }
        }
        "pagehide" => {
            // Close everything so the page is BFCache-eligible. The
            // skill calls this out explicitly: an open WS disqualifies
            // BFCache on every browser.
            for rec in m.connections.values() {
                let _ = rec.socket.close_with_code_and_reason(1001, "pagehide");
            }
        }
        _ => {}
    }
}

fn document_hidden() -> bool {
    web_sys::window()
        .and_then(|w| w.document())
        .map(|d| d.visibility_state() == web_sys::VisibilityState::Hidden)
        .unwrap_or(false)
}

// ---------------------------------------------------------------------------
// Stats publishing + log
// ---------------------------------------------------------------------------

fn publish_stats(state: WsState) {
    let snapshot = state.inner.with_value(|m| build_stats(m));
    state.set_stats.set(snapshot);
}

fn build_stats(m: &ManagerInner) -> ManagerStats {
    let now = wall_now_ms();
    let mut connections: Vec<ConnectionStats> = m
        .connections
        .values()
        .map(|r| ConnectionStats {
            id: r.id,
            state: r.state,
            state_since_ms: r.state_since_ms,
            uptime_ms: r.opened_at_ms.map(|t| now - t).unwrap_or(0),
            in_flight_pings: r.pending_pings.len(),
            last_rtt_ms: r.last_rtt_ms,
            is_active: r.is_active,
        })
        .collect();
    connections.sort_by_key(|c| c.id);

    let widget = derive_widget(m);

    let rtt_30s = rtt_window(&m.rtt_samples, now, RTT_WINDOW_30S);
    let rtt_1m = rtt_window(&m.rtt_samples, now, RTT_WINDOW_1M);
    let rtt_5m = rtt_window(&m.rtt_samples, now, RTT_WINDOW_5M);

    ManagerStats {
        connections,
        active_id: m.active_id,
        reconnect_scheduled: m.reconnect_scheduled,
        reconnect_deferred_until_visible: m.reconnect_deferred_until_visible,
        backoff_attempt: m.backoff_attempt,
        backoff_max: RECONNECT_MAX_ATTEMPTS,
        is_terminal: m.is_terminal,
        last_close_code: m.last_close_code,
        last_close_reason: m.last_close_reason.clone(),
        rtt_30s,
        rtt_1m,
        rtt_5m,
        pings_sent: m.pings_sent,
        pongs_received: m.pongs_received,
        events: m.events.clone(),
        widget,
    }
}

fn derive_widget(m: &ManagerInner) -> WidgetState {
    if m.is_terminal {
        return WidgetState::Terminal;
    }
    let mut has_alive = false;
    let mut has_stale = false;
    let mut has_new = false;
    for r in m.connections.values() {
        match r.state {
            ConnState::Alive => has_alive = true,
            ConnState::Stale => has_stale = true,
            ConnState::New => has_new = true,
            ConnState::Dead => {}
        }
    }
    if has_alive {
        WidgetState::Alive
    } else if has_stale {
        WidgetState::Stale
    } else if has_new {
        WidgetState::Connecting
    } else if m.reconnect_deferred_until_visible {
        WidgetState::Deferred
    } else if m.reconnect_scheduled.is_some() {
        WidgetState::Connecting
    } else {
        WidgetState::Dead
    }
}

fn rtt_window(samples: &VecDeque<(i64, u64)>, now: i64, window_secs: u64) -> RttWindow {
    let cutoff = now - (window_secs as i64) * 1000;
    let mut vs: Vec<u64> = samples
        .iter()
        .filter(|(t, _)| *t >= cutoff)
        .map(|(_, v)| *v)
        .collect();
    if vs.is_empty() {
        return RttWindow::default();
    }
    vs.sort_unstable();
    let count = vs.len();
    let median = vs[count / 2];
    RttWindow {
        count,
        min_ms: Some(*vs.first().unwrap()),
        median_ms: Some(median),
        max_ms: Some(*vs.last().unwrap()),
    }
}

fn log_event(m: &mut ManagerInner, line: &str) {
    m.events.push_back(WsEvent {
        ts_ms: wall_now_ms(),
        line: line.to_string(),
    });
    while m.events.len() > MAX_LOG_ENTRIES {
        m.events.pop_front();
    }
}

// ---------------------------------------------------------------------------
// Domain message dispatch (called outside the manager borrow)
// ---------------------------------------------------------------------------

fn apply_domain_message(state: WsState, msg: ServerMessage) {
    match msg {
        ServerMessage::StateSnapshot(snap) => {
            apply_full_snapshot(
                state.rooms,
                state.plugs,
                state.heating,
                state.lights,
                state.room_names,
                state.plug_names,
                state.heating_names,
                state.light_names,
                snap,
            );
        }
        ServerMessage::Topology(topo) => {
            state.set_topology.set(Some(topo));
        }
        ServerMessage::EventLog(entry) => {
            state.set_log_entries.update(|entries| {
                entries.insert(0, entry);
                entries.truncate(MAX_LOG_ENTRIES);
            });
        }
        ServerMessage::Entity(update) => match update {
            EntityUpdate::Room(room) => {
                upsert_entity(state.rooms, state.room_names, room.name.clone(), room);
            }
            EntityUpdate::Plug(plug) => {
                upsert_entity(state.plugs, state.plug_names, plug.device.clone(), plug);
            }
            EntityUpdate::HeatingZone(zone) => {
                upsert_entity(state.heating, state.heating_names, zone.name.clone(), zone);
            }
            EntityUpdate::Light(light) => {
                upsert_entity(state.lights, state.light_names, light.device.clone(), light);
            }
        },
        ServerMessage::EntityLog {
            entity,
            entries,
            has_more,
        } => {
            apply_entity_log(state.entity_logs, &entity, entries, has_more);
        }
        ServerMessage::Pong { .. } => {
            // Already handled inside the manager — no domain effect.
        }
    }
}

fn apply_entity_log(
    entity_logs: StoredValue<BTreeMap<String, RwSignal<EntityLogPage>>, LocalStorage>,
    entity: &str,
    incoming: Vec<LogEntryDto>,
    has_more: bool,
) {
    let sig = entity_logs.with_value(|m| m.get(entity).copied());
    let Some(sig) = sig else {
        return;
    };
    sig.update(|page| {
        let oldest_existing = page.entries.last().map(|e| e.timestamp_epoch_ms);
        let newest_incoming = incoming.first().map(|e| e.timestamp_epoch_ms);
        let is_older_page = matches!(
            (oldest_existing, newest_incoming),
            (Some(o), Some(n)) if n < o
        );
        if is_older_page {
            page.entries.extend(incoming);
        } else {
            page.entries = incoming;
        }
        page.has_more = has_more;
        page.loading = false;
        page.loaded = true;
    });
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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn wall_now_ms() -> i64 {
    js_sys::Date::now() as i64
}

fn make_nonce() -> String {
    uuid::Uuid::new_v4().to_string()
}

fn build_ws_url() -> String {
    let window = web_sys::window().unwrap();
    let location = window.location();
    let host = location.host().unwrap_or_else(|_| "localhost:8780".into());
    let protocol = location.protocol().unwrap_or_else(|_| "http:".into());
    let ws_protocol = if protocol == "https:" { "wss:" } else { "ws:" };
    format!("{ws_protocol}//{host}/ws")
}
