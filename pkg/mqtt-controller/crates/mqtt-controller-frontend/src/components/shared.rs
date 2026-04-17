//! Shared UI primitives: filter checkbox, JSON button, switch chip, modal,
//! TASS state pill strip.

use leptos::prelude::*;

use mqtt_controller_wire::{SwitchInfo, TassActualInfo, TassTargetInfo};

use crate::ws::WsState;

/// Anything renderable as a short value-pill string. Implemented by
/// each wire-level typed TASS value so `TassStateRow` can stay generic.
pub trait TassValueDisplay {
    fn to_pill(&self) -> String;
}

impl TassValueDisplay for mqtt_controller_wire::RoomTargetValue {
    fn to_pill(&self) -> String {
        use mqtt_controller_wire::RoomTargetValue::*;
        match self {
            Off => "off".into(),
            On { scene_id, cycle_idx } => format!("on · S{scene_id} · #{cycle_idx}"),
        }
    }
}

impl TassValueDisplay for mqtt_controller_wire::RoomActualValue {
    fn to_pill(&self) -> String {
        use mqtt_controller_wire::RoomActualValue::*;
        match self {
            On => "on".into(),
            Off => "off".into(),
        }
    }
}

impl TassValueDisplay for mqtt_controller_wire::PlugTargetValue {
    fn to_pill(&self) -> String {
        use mqtt_controller_wire::PlugTargetValue::*;
        match self {
            On => "on".into(),
            Off => "off".into(),
        }
    }
}

impl TassValueDisplay for mqtt_controller_wire::PlugActualValue {
    fn to_pill(&self) -> String {
        let base = if self.on { "on" } else { "off" };
        match self.power {
            Some(w) => format!("{base} · {w:.1} W"),
            None => base.to_string(),
        }
    }
}

impl TassValueDisplay for mqtt_controller_wire::HeatingZoneTargetValue {
    fn to_pill(&self) -> String {
        use mqtt_controller_wire::HeatingZoneTargetValue::*;
        match self {
            Heating => "heating".into(),
            Off => "off".into(),
        }
    }
}

impl TassValueDisplay for mqtt_controller_wire::HeatingZoneActualValue {
    fn to_pill(&self) -> String {
        let base = if self.relay_on { "relay on" } else { "relay off" };
        match self.temperature {
            Some(t) => format!("{base} · {t:.1}°C"),
            None => base.to_string(),
        }
    }
}

impl TassValueDisplay for mqtt_controller_wire::LightActualValue {
    fn to_pill(&self) -> String {
        let on = if self.on { "on" } else { "off" };
        match self.brightness {
            Some(b) => {
                let pct = (b as u16 * 100 / 254) as u8;
                format!("{on} · {pct}%")
            }
            None => on.to_string(),
        }
    }
}

impl TassValueDisplay for mqtt_controller_wire::TrvTargetValue {
    fn to_pill(&self) -> String {
        use mqtt_controller_wire::TrvTargetValue::*;
        match self {
            Setpoint { temperature } => format!("{temperature:.1}°C"),
            Inhibited => "inhibited (window)".into(),
            ForcedOpen { reason } => format!("forced · {reason}"),
        }
    }
}

/// Placeholder impl for the unit type so callers can pass `None::<()>`
/// when an entity has no typed value for one side of the TASS row.
impl TassValueDisplay for () {
    fn to_pill(&self) -> String {
        String::new()
    }
}

/// Small checkbox that toggles entity membership in the filter set.
#[component]
pub fn EntityFilterCheckbox(name: String) -> impl IntoView {
    let ws = expect_context::<WsState>();
    let filter_entities = ws.filter_entities;
    let name_for_prop = name.clone();
    let name_for_change = name.clone();
    let ws_for_change = ws.clone();
    view! {
        <input
            type="checkbox"
            class="entity-filter-cb"
            prop:checked=move || filter_entities.get().contains(&name_for_prop)
            on:change=move |_| ws_for_change.toggle_filter(&name_for_change)
        />
    }
}

/// JSON popup button. Clicking opens the global modal with the given
/// title and pretty-printed JSON body. The body is computed lazily so
/// no work is done until the user clicks.
#[component]
pub fn JsonButton<F>(title: String, build_json: F) -> impl IntoView
where
    F: Fn() -> String + 'static,
{
    let ws = expect_context::<WsState>();
    view! {
        <button
            class="btn detail-btn"
            title="Show JSON"
            on:click=move |_| {
                ws.show_json(title.clone(), build_json());
            }
        >
            "JSON"
        </button>
    }
}

/// One switch chip with a hover-activated popup listing the actions
/// bound to each button on the device.
#[component]
pub fn SwitchChip(info: SwitchInfo) -> impl IntoView {
    let device = info.device.clone();
    let buttons = info.buttons.clone();

    let popup_rows: Vec<_> = buttons
        .iter()
        .flat_map(|b| {
            let button = b.button.clone();
            b.actions.iter().map(move |a| {
                (button.clone(), a.gesture.clone(), a.description.clone())
            })
        })
        .collect();

    view! {
        <span class="switch-chip">
            <span class="switch-name">{device}</span>
            {(!popup_rows.is_empty()).then(|| view! {
                <div class="switch-popup">
                    <table class="switch-popup-table">
                        <thead>
                            <tr>
                                <th>"Button"</th>
                                <th>"Gesture"</th>
                                <th>"Effect"</th>
                            </tr>
                        </thead>
                        <tbody>
                            {popup_rows.into_iter().map(|(btn, gesture, desc)| view! {
                                <tr>
                                    <td class="mono">{btn}</td>
                                    <td class="mono">{gesture}</td>
                                    <td>{desc}</td>
                                </tr>
                            }).collect::<Vec<_>>()}
                        </tbody>
                    </table>
                </div>
            })}
        </span>
    }
}

/// Global JSON modal. Rendered once at the root; reads
/// `WsState::json_popup` to decide visibility.
#[component]
pub fn JsonModal() -> impl IntoView {
    let ws = expect_context::<WsState>();
    let popup = ws.json_popup;

    view! {
        {move || {
            let Some(p) = popup.get() else { return ().into_any(); };
            let title = p.title.clone();
            let body = p.json.clone();
            let body_for_copy = body.clone();
            let ws_close = ws.clone();
            let ws_close_backdrop = ws.clone();
            view! {
                <div class="modal-backdrop" on:click=move |_| ws_close_backdrop.hide_json()>
                    <div class="modal-panel" on:click=|e| e.stop_propagation()>
                        <div class="modal-header">
                            <span class="modal-title">{title}</span>
                            <button
                                class="btn"
                                on:click=move |_| {
                                    if let Some(window) = web_sys::window() {
                                        let clipboard = window.navigator().clipboard();
                                        let _ = clipboard.write_text(&body_for_copy);
                                    }
                                }
                            >
                                "Copy"
                            </button>
                            <button
                                class="btn"
                                on:click=move |_| ws_close.hide_json()
                            >
                                "Close"
                            </button>
                        </div>
                        <pre class="modal-body">{body}</pre>
                    </div>
                </div>
            }.into_any()
        }}
    }
}

/// Render a TASS state row with typed target/actual values. Generic
/// over the target and actual kinds so each entity passes its own
/// typed DTOs.
pub fn tass_state_row<T, A>(
    target: Option<TassTargetInfo>,
    target_value: Option<T>,
    actual: Option<TassActualInfo>,
    actual_value: Option<A>,
) -> impl IntoView
where
    T: TassValueDisplay + 'static,
    A: TassValueDisplay + 'static,
{
    if target.is_none() && actual.is_none() {
        return ().into_any();
    }
    let target_pill = target_value.map(|v| v.to_pill());
    let actual_pill = actual_value.map(|v| v.to_pill());
    view! {
        <div class="tass-line">
            {target.map(|t| {
                let phase = t.phase.clone();
                let phase_class = format!("badge phase-{phase}");
                let owner = t.owner.clone();
                let owner_class = format!("badge owner-{owner}");
                let since = t.since_ago_ms.map(format_ago_ms);
                view! {
                    <span class="tass-group">
                        <span class="tass-label">"target"</span>
                        <span class=phase_class>{phase}</span>
                        {target_pill.map(|p| view! {
                            <span class="badge tass-value">{p}</span>
                        })}
                        {(!owner.is_empty()).then(|| view! {
                            <span class=owner_class>{owner}</span>
                        })}
                        {since.map(|s| view! { <span class="tass-since">{s}</span> })}
                    </span>
                }
            })}
            {actual.map(|a| {
                let freshness = a.freshness.clone();
                let freshness_class = format!("badge freshness-{freshness}");
                let since = a.since_ago_ms.map(format_ago_ms);
                view! {
                    <span class="tass-group">
                        <span class="tass-label">"actual"</span>
                        <span class=freshness_class>{freshness}</span>
                        {actual_pill.map(|p| view! {
                            <span class="badge tass-value">{p}</span>
                        })}
                        {since.map(|s| view! { <span class="tass-since">{s}</span> })}
                    </span>
                }
            })}
        </div>
    }.into_any()
}

/// Pretty-print an elapsed millisecond count as "3s", "12m", or "1h 4m".
pub fn format_ago_ms(ms: u64) -> String {
    let secs = ms / 1000;
    if secs < 60 {
        format!("{secs}s")
    } else if secs < 3600 {
        format!("{}m {}s", secs / 60, secs % 60)
    } else {
        let h = secs / 3600;
        let m = (secs % 3600) / 60;
        format!("{h}h {m}m")
    }
}
