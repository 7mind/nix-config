//! Light-zone (room) cards.
//!
//! The outer `RoomCards` drives a keyed `<For>` over `room_names` so
//! only changed rooms re-render. Each `RoomCard` subscribes to its own
//! `RwSignal<RoomSnapshot>`, so updates to one room don't invalidate
//! any other.

use leptos::prelude::*;

use mqtt_controller_wire::{ClientMessage, RoomSnapshot};

use crate::components::shared::{
    format_ago_ms, EntityFilterCheckbox, JsonButton, SwitchChip,
};
use crate::ws::WsState;

#[component]
pub fn RoomCards() -> impl IntoView {
    let ws = expect_context::<WsState>();
    let room_names = ws.room_names;

    view! {
        <div class="card-grid">
            <For
                each=move || room_names.get()
                key=|name| name.clone()
                children=move |name| {
                    view! { <RoomCard name=name /> }
                }
            />
        </div>
    }
}

#[component]
fn RoomCard(name: String) -> impl IntoView {
    let ws = expect_context::<WsState>();
    let Some(signal) = ws.room_signal(&name) else {
        return view! { <div class="card">"(missing room "{name}")"</div> }.into_any();
    };

    let room_name_for_actions = name.clone();
    let display_name = name.clone();
    let display_name_title = name.clone();
    let filter_name = name.clone();
    let json_title = format!("Room: {name}");

    view! {
        <div class="card">
            <div class="card-header">
                <EntityFilterCheckbox name=filter_name />
                <StatusDot on=Signal::derive(move || signal.get().physically_on) />
                <span class="card-name" title=display_name_title>{display_name}</span>
                <JsonButton
                    title=json_title
                    build_json=move || {
                        serde_json::to_string_pretty(&signal.get()).unwrap_or_default()
                    }
                />
            </div>

            <RoomMeta signal=signal />
            <RoomTassLine signal=signal />

            <RoomLights signal=signal />

            <RoomControls signal=signal room=room_name_for_actions />

            <RoomSwitches signal=signal />
            <RoomMotionSensors signal=signal />
        </div>
    }.into_any()
}

#[component]
fn StatusDot(on: Signal<bool>) -> impl IntoView {
    view! {
        <span class=move || if on.get() { "status-dot on" } else { "status-dot off" }></span>
    }
}

#[component]
fn RoomMeta(signal: RwSignal<RoomSnapshot>) -> impl IntoView {
    view! {
        <div class="card-meta">
            {move || {
                let r = signal.get();
                let slot = r.active_slot.clone();
                let motion_owned = r.motion_owned;
                let motion_sensors = r.motion_active_sensors.clone();
                let cycle_idx = r.cycle_idx;
                view! {
                    {slot.map(|s| view! { <span class="badge slot">{s}</span> })}
                    {motion_owned.then(|| view! { <span class="badge motion">"motion"</span> })}
                    {(!motion_sensors.is_empty()).then(|| view! {
                        <span class="badge motion">{motion_sensors.join(", ")}</span>
                    })}
                    <span class="cycle-info">{format!(" cycle: {cycle_idx}")}</span>
                }
            }}
        </div>
    }
}

#[component]
fn RoomTassLine(signal: RwSignal<RoomSnapshot>) -> impl IntoView {
    view! {
        {move || {
            let r = signal.get();
            let Some(target) = r.target.clone() else { return ().into_any(); };
            let Some(actual) = r.actual.clone() else { return ().into_any(); };
            let target_text = if target.value.is_empty() {
                "unset".to_string()
            } else {
                format!("{} ({})", target.value, target.phase)
            };
            let actual_text = if actual.value.is_empty() {
                format!("— ({})", actual.freshness)
            } else {
                format!("{} ({})", actual.value, actual.freshness)
            };
            let owner = (!target.owner.is_empty()).then(|| target.owner.clone());
            view! {
                <div class="tass-line">
                    <span class="tass-label">"target"</span>
                    <span class="tass-value">{target_text}</span>
                    {owner.map(|o| view! { <span class="tass-owner">{format!("by {o}")}</span> })}
                    <span class="tass-label">"actual"</span>
                    <span class="tass-value">{actual_text}</span>
                </div>
            }.into_any()
        }}
    }
}

#[component]
fn RoomLights(signal: RwSignal<RoomSnapshot>) -> impl IntoView {
    view! {
        {move || {
            let r = signal.get();
            if r.lights.is_empty() {
                return ().into_any();
            }
            let physically_on = r.physically_on;
            let lights = r.lights.clone();
            view! {
                <div class="lights-section">
                    <div class="section-label">"Lights"</div>
                    <div class="lights-grid">
                        {lights.into_iter().map(|light| {
                            let device_title = light.device.clone();
                            view! {
                                <div class="light-tile" title=device_title>
                                    <span class=if physically_on { "status-dot on" } else { "status-dot off" }></span>
                                    <span class="light-name">{light.device}</span>
                                </div>
                            }
                        }).collect::<Vec<_>>()}
                    </div>
                </div>
            }.into_any()
        }}
    }
}

#[component]
fn RoomControls(signal: RwSignal<RoomSnapshot>, room: String) -> impl IntoView {
    let ws = expect_context::<WsState>();
    let room_for_off = room.clone();
    view! {
        <div class="card-controls">
            {move || {
                let scenes = signal.with(|r| r.scene_ids.clone());
                let room = room.clone();
                let ws_inner = ws.clone();
                scenes.into_iter().map(|id| {
                    let ws_btn = ws_inner.clone();
                    let room_btn = room.clone();
                    view! {
                        <button
                            class="btn"
                            on:click=move |_| {
                                ws_btn.send(&ClientMessage::RecallScene {
                                    room: room_btn.clone(),
                                    scene_id: id,
                                });
                            }
                        >
                            {format!("S{id}")}
                        </button>
                    }
                }).collect::<Vec<_>>()
            }}
            <button
                class="btn off-btn"
                on:click={
                    let ws = ws.clone();
                    move |_| {
                        ws.send(&ClientMessage::SetRoomOff {
                            room: room_for_off.clone(),
                        });
                    }
                }
            >
                "OFF"
            </button>
        </div>
    }
}

#[component]
fn RoomSwitches(signal: RwSignal<RoomSnapshot>) -> impl IntoView {
    view! {
        {move || {
            let switches = signal.with(|r| r.switches.clone());
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

#[component]
fn RoomMotionSensors(signal: RwSignal<RoomSnapshot>) -> impl IntoView {
    let ws = expect_context::<WsState>();
    let tick = ws.tick_seq;
    view! {
        {move || {
            let r = signal.get();
            // Subscribe to the 1s tick so relative time labels refresh.
            let _ = tick.get();
            if r.motion_sensors.is_empty() {
                return ().into_any();
            }
            let sensors = r.motion_sensors.clone();
            let cooldown_remaining = r.motion_cooldown_remaining_secs;
            let cooldown_total = r.motion_off_cooldown_secs;
            view! {
                <div class="motion-section">
                    <div class="section-label">"Motion"</div>
                    {cooldown_remaining.map(|remaining| view! {
                        <div class="cooldown-row">
                            <span class="badge inhibited">
                                {format!("cooldown: {remaining}s / {cooldown_total}s")}
                            </span>
                        </div>
                    })}
                    <div class="motion-list">
                        {sensors.into_iter().map(|s| view! { <MotionSensorRow info=s /> }).collect::<Vec<_>>()}
                    </div>
                </div>
            }.into_any()
        }}
    }
}

#[component]
fn MotionSensorRow(info: mqtt_controller_wire::MotionSensorInfo) -> impl IntoView {
    let occupied_class = match info.occupied {
        Some(true) => "status-dot on",
        Some(false) => "status-dot off",
        None => "status-dot off unknown",
    };
    let occupied_text = match info.occupied {
        Some(true) => "occupied",
        Some(false) => "clear",
        None => "?",
    };
    let freshness = info.freshness.clone();
    let since = info.since_ago_ms.map(format_ago_ms);
    let illuminance = info.illuminance.map(|l| format!("{l} lx"));
    let timeout_text = (info.occupancy_timeout_secs > 0)
        .then(|| format!("timeout {}s", info.occupancy_timeout_secs));
    let max_illum_text = info.max_illuminance.map(|m| format!("max {m} lx"));

    let device_title = info.device.clone();
    view! {
        <div class="motion-row" title=device_title>
            <span class=occupied_class></span>
            <span class="motion-device">{info.device}</span>
            <span class="motion-state">{occupied_text}</span>
            <span class="motion-meta">
                {since.map(|s| view! { <span>{format!("·{s}")}</span> })}
                {(!freshness.is_empty() && freshness != "fresh")
                    .then(|| view! { <span class="badge inhibited">{freshness}</span> })}
                {illuminance.map(|l| view! { <span>{format!("·{l}")}</span> })}
                {timeout_text.map(|t| view! { <span class="muted">{format!("·{t}")}</span> })}
                {max_illum_text.map(|m| view! { <span class="muted">{format!("·{m}")}</span> })}
            </span>
        </div>
    }
}
