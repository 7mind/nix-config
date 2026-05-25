//! Connection-health indicator.
//!
//! Compact widget (single 32px SVG) living in the header, plus a
//! hover-revealed tooltip with the full diagnostic surface (per-conn
//! state, RTT windows, packet loss, backoff, last close code, event
//! log). Encodes state in two independent channels (color + label
//! text) per the `resilient-ws-ui` skill's accessibility rule, and
//! mirrors the state in `document.title` so backgrounded tabs surface
//! it.

use leptos::prelude::*;
use leptos::reactive::owner::LocalStorage;

use crate::ws::{
    ConnState, ConnectionStats, ManagerStats, ReconnectScheduled, WidgetState, WsState,
    CONNECT_TIMEOUT_MS, STALE_GRACE_PERIOD_MS,
};

/// Compact circular indicator with countdown ring. The ring is rendered
/// as two SVG arcs (background + foreground) so the depleting-budget
/// visualisation is independent of the dot color.
#[component]
pub fn WsIndicator(ws: WsState) -> impl IntoView {
    let stats = ws.stats;
    let now_ms = ws.now_ms;

    // Document.title mirror — runs whenever stats change. The hidden-tab
    // affordance is the whole point: when the indicator is off-screen,
    // the tab title is what the user actually sees.
    Effect::new(move |_| {
        let s = stats.get();
        let alive = s
            .connections
            .iter()
            .filter(|c| c.state == ConnState::Alive)
            .count();
        let total = s.connections.len();
        let suffix = match s.widget {
            WidgetState::Terminal => " [STOPPED]",
            WidgetState::Stale => " [STALE]",
            WidgetState::Dead => " [DISCONNECTED]",
            WidgetState::Deferred => " [DEFERRED]",
            WidgetState::Connecting => " [CONNECTING]",
            WidgetState::Alive => "",
        };
        if let Some(window) = web_sys::window() {
            if let Some(doc) = window.document() {
                doc.set_title(&format!("({alive}/{total}) MQTT Controller{suffix}"));
            }
        }
    });

    let hovered = RwSignal::new_local(false);

    view! {
        <div
            class="ws-indicator-wrap"
            on:mouseenter=move |_| hovered.set(true)
            on:mouseleave=move |_| hovered.set(false)
        >
            <button
                class="ws-indicator"
                data-state=move || stats.get().widget.label()
                aria-label=move || aria_label(&stats.get())
                title=move || aria_label(&stats.get())
                on:click=move |_| ws.manual_retry()
            >
                <svg viewBox="0 0 32 32" class="ws-indicator-svg">
                    // Background track for the countdown ring.
                    <circle cx="16" cy="16" r="13" class="ws-indicator-track" />
                    // Countdown ring (foreground arc). `pathLength=100`
                    // lets us drive the dash array as a percentage.
                    <circle
                        cx="16" cy="16" r="13" pathLength="100"
                        class="ws-indicator-ring"
                        stroke-dasharray=move || {
                            let frac = compute_ring_remaining(&stats.get(), now_ms.get())
                                .unwrap_or(0.0);
                            format!("{:.1} 100", frac * 100.0)
                        }
                    />
                    // Central state dot.
                    <circle cx="16" cy="16" r="6" class="ws-indicator-dot" />
                    // Terminal "×" overlay when the manager has given up.
                    <Show when=move || stats.get().widget == WidgetState::Terminal>
                        <path d="M11 11 L21 21 M21 11 L11 21" class="ws-indicator-x" />
                    </Show>
                </svg>
            </button>
            <Show when=move || hovered.get()>
                <WsTooltip stats=stats now_ms=now_ms />
            </Show>
        </div>
    }
}

fn aria_label(s: &ManagerStats) -> String {
    let active = s
        .connections
        .iter()
        .filter(|c| c.is_active)
        .next()
        .map(|c| format!(" conn#{} {}", c.id, c.state.label()))
        .unwrap_or_default();
    format!("WebSocket: {}{}", s.widget.label(), active)
}

/// Returns the fraction of the current waiting budget that remains,
/// in `[0.0, 1.0]`. `None` means the state has no countdown to render
/// — the ring is then empty (we still draw the background track so the
/// widget is visually stable).
fn compute_ring_remaining(stats: &ManagerStats, now: i64) -> Option<f64> {
    fn fraction(start: i64, end: i64, now: i64) -> Option<f64> {
        let total = (end - start).max(1);
        let remaining = (end - now).max(0);
        Some(((remaining as f64) / (total as f64)).clamp(0.0, 1.0))
    }
    match stats.widget {
        WidgetState::Alive => {
            // Steady state — no countdown to show. The pulsing dot
            // (CSS animation) already signals "alive"; depleting a
            // ring continuously would just be alarming noise.
            None
        }
        WidgetState::Stale => {
            let stale = stats
                .connections
                .iter()
                .find(|c| c.state == ConnState::Stale)?;
            fraction(
                stale.state_since_ms,
                stale.state_since_ms + STALE_GRACE_PERIOD_MS as i64,
                now,
            )
        }
        WidgetState::Connecting => {
            // Either a NEW conn (connect timeout) or a scheduled
            // reconnect — whichever is outstanding.
            if let Some(ReconnectScheduled {
                started_at_ms,
                fires_at_ms,
            }) = stats.reconnect_scheduled
            {
                return fraction(started_at_ms, fires_at_ms, now);
            }
            let new_conn = stats
                .connections
                .iter()
                .find(|c| c.state == ConnState::New)?;
            fraction(
                new_conn.state_since_ms,
                new_conn.state_since_ms + CONNECT_TIMEOUT_MS as i64,
                now,
            )
        }
        WidgetState::Dead | WidgetState::Terminal | WidgetState::Deferred => None,
    }
}

#[component]
fn WsTooltip(stats: ReadSignal<ManagerStats>, now_ms: ReadSignal<i64>) -> impl IntoView {
    view! {
        <div class="ws-tooltip" role="tooltip">
            <div class="ws-tooltip-header">
                <strong>"Connection: "</strong>
                {move || stats.get().widget.label().to_string()}
            </div>
            <PoolBlock stats=stats now_ms=now_ms />
            <RttBlock stats=stats />
            <BackoffBlock stats=stats now_ms=now_ms />
            <LastCloseBlock stats=stats />
            <LogBlock stats=stats />
            <div class="ws-tooltip-hint">"click indicator to retry"</div>
        </div>
    }
}

#[component]
fn PoolBlock(
    stats: ReadSignal<ManagerStats>,
    now_ms: ReadSignal<i64>,
) -> impl IntoView {
    view! {
        <div class="ws-tooltip-section">
            <div class="ws-tooltip-label">"Pool"</div>
            <For
                each=move || stats.get().connections.clone()
                key=|c| c.id
                children=move |c: ConnectionStats| {
                    let id = c.id;
                    let state_label = c.state.label();
                    let is_active = c.is_active;
                    let in_flight = c.in_flight_pings;
                    let last_rtt = c.last_rtt_ms;
                    let state_since = c.state_since_ms;
                    view! {
                        <div class=move || {
                            if is_active { "ws-conn-card ws-conn-card-active" }
                            else { "ws-conn-card" }
                        }>
                            <span class="ws-conn-id">"#" {id}</span>
                            <span class="ws-conn-state">{state_label}</span>
                            <span class="ws-conn-age">
                                {move || fmt_duration(now_ms.get() - state_since)}
                            </span>
                            <span class="ws-conn-pings">
                                "in-flight: " {in_flight}
                            </span>
                            <span class="ws-conn-rtt">
                                {move || match last_rtt {
                                    Some(rtt) => format!("rtt {rtt}ms"),
                                    None => "rtt —".to_string(),
                                }}
                            </span>
                        </div>
                    }
                }
            />
            <Show when=move || stats.get().connections.is_empty()>
                <div class="ws-tooltip-empty">"no live connections"</div>
            </Show>
        </div>
    }
}

#[component]
fn RttBlock(stats: ReadSignal<ManagerStats>) -> impl IntoView {
    view! {
        <div class="ws-tooltip-section">
            <div class="ws-tooltip-label">"RTT windows"</div>
            <div class="ws-rtt-row">
                <div>"30s: " {move || fmt_rtt(stats.get().rtt_30s)}</div>
                <div>"1m: " {move || fmt_rtt(stats.get().rtt_1m)}</div>
                <div>"5m: " {move || fmt_rtt(stats.get().rtt_5m)}</div>
            </div>
            <div class="ws-tooltip-loss">
                "packets: sent " {move || stats.get().pings_sent}
                ", received " {move || stats.get().pongs_received}
                ", loss " {move || fmt_loss(&stats.get())} "%"
            </div>
        </div>
    }
}

#[component]
fn BackoffBlock(
    stats: ReadSignal<ManagerStats>,
    now_ms: ReadSignal<i64>,
) -> impl IntoView {
    view! {
        <div class="ws-tooltip-section">
            <div class="ws-tooltip-label">"Reconnect"</div>
            <div class="ws-tooltip-line">
                "attempt "
                {move || stats.get().backoff_attempt}
                " / "
                {move || stats.get().backoff_max}
            </div>
            <div class="ws-tooltip-line">
                {move || {
                    let s = stats.get();
                    if s.is_terminal {
                        "stopped — manual retry required".to_string()
                    } else if s.reconnect_deferred_until_visible {
                        "deferred — tab hidden".to_string()
                    } else if let Some(rs) = s.reconnect_scheduled {
                        let remaining = (rs.fires_at_ms - now_ms.get()).max(0);
                        format!("next attempt in {}", fmt_duration(remaining))
                    } else {
                        "idle".to_string()
                    }
                }}
            </div>
        </div>
    }
}

#[component]
fn LastCloseBlock(stats: ReadSignal<ManagerStats>) -> impl IntoView {
    view! {
        <Show when=move || stats.get().last_close_code.is_some()>
            <div class="ws-tooltip-section">
                <div class="ws-tooltip-label">"Last close"</div>
                <div class="ws-tooltip-line">
                    {move || {
                        let s = stats.get();
                        format!(
                            "code {} ({})",
                            s.last_close_code.unwrap_or(0),
                            s.last_close_reason.as_deref().unwrap_or("-")
                        )
                    }}
                </div>
            </div>
        </Show>
    }
}

#[component]
fn LogBlock(stats: ReadSignal<ManagerStats>) -> impl IntoView {
    view! {
        <div class="ws-tooltip-section ws-log">
            <div class="ws-tooltip-label">"Event log"</div>
            <For
                each=move || {
                    // Render most-recent first, capped to last 20 lines.
                    let s = stats.get();
                    s.events.iter().rev().take(20).cloned().collect::<Vec<_>>()
                }
                key=|e| (e.ts_ms, e.line.clone())
                children=|e| view! {
                    <div class="ws-log-line">
                        <span class="ws-log-ts">{fmt_clock(e.ts_ms)}</span>
                        " "
                        <span class="ws-log-msg">{e.line.clone()}</span>
                    </div>
                }
            />
        </div>
    }
}

fn fmt_duration(ms: i64) -> String {
    let s = ms.max(0) / 1000;
    if s < 60 {
        format!("{s}s")
    } else if s < 3600 {
        format!("{}m{}s", s / 60, s % 60)
    } else {
        format!("{}h{}m", s / 3600, (s % 3600) / 60)
    }
}

fn fmt_clock(ms: i64) -> String {
    let date = js_sys::Date::new(&wasm_bindgen::JsValue::from_f64(ms as f64));
    let h = date.get_hours();
    let m = date.get_minutes();
    let s = date.get_seconds();
    format!("{h:02}:{m:02}:{s:02}")
}

fn fmt_rtt(w: crate::ws::RttWindow) -> String {
    match (w.min_ms, w.median_ms, w.max_ms) {
        (Some(min), Some(med), Some(max)) => {
            format!("n={} {min}/{med}/{max}ms", w.count)
        }
        _ => "n=0".to_string(),
    }
}

fn fmt_loss(s: &ManagerStats) -> String {
    if s.pings_sent == 0 {
        return "0.0".to_string();
    }
    let lost = s.pings_sent.saturating_sub(s.pongs_received);
    let pct = (lost as f64) * 100.0 / (s.pings_sent as f64);
    format!("{pct:.1}")
}

// Silence unused-import diagnostics on the leptos `LocalStorage` re-
// export when the file is compiled in isolation by docs.
#[allow(dead_code)]
type _Keep = std::marker::PhantomData<LocalStorage>;
