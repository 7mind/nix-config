//! Smart-plug cards with TASS summary, kill-switch timers, linked switches.

use leptos::prelude::*;

use mqtt_controller_wire::{ClientMessage, PlugSnapshot};

use crate::components::shared::{
    format_ago_ms, tass_state_row, EntityFilterCheckbox, JsonButton, LogButton, SwitchChip,
};
use crate::ws::WsState;

#[component]
pub fn PlugCards() -> impl IntoView {
    let ws = expect_context::<WsState>();
    let plug_names = ws.plug_names;

    view! {
        <div class="card-grid">
            <For
                each=move || plug_names.get()
                key=|name| name.clone()
                children=move |name| {
                    view! { <PlugCard device=name /> }
                }
            />
        </div>
    }
}

#[component]
fn PlugCard(device: String) -> impl IntoView {
    let ws = expect_context::<WsState>();
    let Some(signal) = ws.plug_signal(&device) else {
        return view! { <div class="card">"(missing plug "{device}")"</div> }.into_any();
    };

    let device_for_toggle = device.clone();
    let display_device = device.clone();
    let display_device_title = device.clone();
    let json_device = device.clone();

    view! {
        <div class="card">
            <div class="card-header">
                <EntityFilterCheckbox name=device.clone() />
                <span class=move || if signal.with(|p| p.on) { "status-dot on" } else { "status-dot off" }></span>
                <span class="card-name" title=display_device_title>{display_device}</span>
                <JsonButton
                    title=format!("Plug: {}", json_device)
                    build_json=move || serde_json::to_string_pretty(&signal.get()).unwrap_or_default()
                />
                <LogButton entity=device.clone() />
            </div>

            <PlugMeta signal=signal />
            <PlugTassLine signal=signal />
            <PlugKillSwitches signal=signal />

            <div class="card-controls">
                <button
                    class="btn"
                    on:click={
                        let ws = ws.clone();
                        move |_| {
                            ws.send(&ClientMessage::TogglePlug {
                                device: device_for_toggle.clone(),
                            });
                        }
                    }
                >
                    "Toggle"
                </button>
            </div>

            <PlugSwitches signal=signal />
        </div>
    }.into_any()
}

#[component]
fn PlugMeta(signal: RwSignal<PlugSnapshot>) -> impl IntoView {
    view! {
        <div class="card-meta">
            {move || {
                let p = signal.get();
                let status = if p.on { "ON" } else { "OFF" };
                let power = p.power_watts.map(|w| format!(" · {w:.1} W"));
                view! {
                    <span>{status}</span>
                    {power.map(|w| view! { <span>{w}</span> })}
                }
            }}
        </div>
    }
}

#[component]
fn PlugTassLine(signal: RwSignal<PlugSnapshot>) -> impl IntoView {
    view! {
        {move || {
            let p = signal.get();
            tass_state_row(p.target, p.target_value, p.actual, p.actual_value)
        }}
    }
}

#[component]
fn PlugKillSwitches(signal: RwSignal<PlugSnapshot>) -> impl IntoView {
    let ws = expect_context::<WsState>();
    let tick = ws.tick_seq;
    view! {
        {move || {
            let p = signal.get();
            // Subscribe to the 1s tick so the countdown visibly ticks.
            let _ = tick.get();
            if p.kill_switch_rules.is_empty() && p.idle_since_ago_ms.is_none() {
                return ().into_any();
            }
            let idle = p.idle_since_ago_ms;
            let holdoff = p.kill_switch_holdoff_secs;
            let rules = p.kill_switch_rules.clone();

            let badge = idle.zip(holdoff).map(|(elapsed_ms, total_s)| {
                let elapsed_s = elapsed_ms / 1000;
                let remaining = total_s.saturating_sub(elapsed_s);
                let total_min = total_s / 60;
                let text = if remaining < 60 {
                    format!("kill: {remaining}s / {total_min}m")
                } else {
                    format!("kill: {}m / {total_min}m", remaining / 60)
                };
                view! { <span class="badge kill-switch">{text}</span> }
            });

            view! {
                <div class="killswitch-section">
                    {badge}
                    {(!rules.is_empty()).then(|| view! {
                        <div class="killswitch-rules">
                            {rules.into_iter().map(|r| {
                                let state_class = match r.state.as_str() {
                                    "armed" => "badge heat",
                                    "idle" => "badge motion",
                                    "suppressed" => "badge inhibited",
                                    _ => "badge unknown",
                                };
                                view! {
                                    <div class="killswitch-rule">
                                        <span class="mono">{r.rule_name}</span>
                                        <span class=state_class>{r.state}</span>
                                        <span class="muted">
                                            {format!(" ·< {} W for {} s", r.threshold_watts, r.holdoff_secs)}
                                        </span>
                                        {r.idle_since_ago_ms.map(|ms| view! {
                                            <span class="muted">{format!(" · idle {}", format_ago_ms(ms))}</span>
                                        })}
                                    </div>
                                }
                            }).collect::<Vec<_>>()}
                        </div>
                    })}
                </div>
            }.into_any()
        }}
    }
}

#[component]
fn PlugSwitches(signal: RwSignal<PlugSnapshot>) -> impl IntoView {
    view! {
        {move || {
            let switches = signal.with(|p| p.linked_switches.clone());
            if switches.is_empty() {
                return ().into_any();
            }
            view! {
                <div class="switches-section">
                    <div class="section-label">"Switches"</div>
                    <div class="switch-list">
                        {switches.into_iter().map(|s| view! { <SwitchChip info=s /> }).collect::<Vec<_>>()}
                    </div>
                </div>
            }.into_any()
        }}
    }
}
