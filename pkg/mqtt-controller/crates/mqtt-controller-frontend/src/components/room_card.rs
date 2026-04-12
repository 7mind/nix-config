//! Room state cards with controls.

use leptos::prelude::*;

use mqtt_controller_wire::{ClientMessage, RoomSnapshot};

use crate::ws::WsState;

#[component]
pub fn RoomCards() -> impl IntoView {
    let ws = expect_context::<WsState>();
    let snapshot = ws.snapshot;

    view! {
        <div class="card-grid">
            {move || {
                snapshot.get().map(|snap| {
                    snap.rooms.iter().map(|room| {
                        let room = room.clone();
                        view! { <RoomCard room=room /> }
                    }).collect::<Vec<_>>()
                }).unwrap_or_default()
            }}
        </div>
    }
}

#[component]
fn RoomCard(room: RoomSnapshot) -> impl IntoView {
    let ws = expect_context::<WsState>();
    let room_name = room.name.clone();
    let display_name = room.name.clone();
    let filter_name = room.name.clone();
    let detail_name = room.name.clone();
    let on_class = if room.physically_on { "status-dot on" } else { "status-dot off" };

    let scene_buttons: Vec<_> = room
        .scene_ids
        .iter()
        .map(|&id| {
            let ws = ws.clone();
            let room = room_name.clone();
            view! {
                <button
                    class="btn"
                    on:click=move |_| {
                        ws.send(&ClientMessage::RecallScene {
                            room: room.clone(),
                            scene_id: id,
                        });
                    }
                >
                    {format!("S{id}")}
                </button>
            }
        })
        .collect();

    let off_ws = ws.clone();
    let off_room = room_name.clone();

    let slot_badge = room.active_slot.clone().map(|s| {
        view! { <span class="badge slot">{s}</span> }
    });
    let motion_badge = room.motion_owned.then(|| {
        view! { <span class="badge motion">"motion"</span> }
    });
    let sensor_badge = if !room.motion_active_sensors.is_empty() {
        let sensors = room.motion_active_sensors.join(", ");
        Some(view! { <span class="badge motion">{sensors}</span> })
    } else {
        None
    };
    let cycle_text = format!(" cycle: {}", room.cycle_idx);

    let json_text = serde_json::to_string_pretty(&room).unwrap_or_default();

    let filter_ws = ws.clone();
    let filter_entities = ws.filter_entities;
    let detail_entity = ws.detail_entity;

    let detail_ws = ws.clone();

    let filter_name_cb = filter_name.clone();

    view! {
        <div class="card">
            <div class="card-header">
                <input
                    type="checkbox"
                    class="entity-filter-cb"
                    prop:checked=move || filter_entities.get().contains(&filter_name_cb)
                    on:change={
                        let name = filter_name.clone();
                        move |_| filter_ws.toggle_filter(&name)
                    }
                />
                <span class=on_class></span>
                <span class="card-name">{display_name.clone()}</span>
                <button
                    class="btn detail-btn"
                    on:click={
                        let name = detail_name.clone();
                        move |_| {
                            detail_ws.set_detail_entity.update(|current| {
                                if current.as_deref() == Some(&name) {
                                    *current = None;
                                } else {
                                    *current = Some(name.clone());
                                }
                            });
                        }
                    }
                >
                    "JSON"
                </button>
            </div>
            <div class="card-meta">
                {slot_badge}
                {motion_badge}
                {sensor_badge}
                {cycle_text}
            </div>
            <div class="card-controls">
                {scene_buttons}
                <button
                    class="btn off-btn"
                    on:click=move |_| {
                        off_ws.send(&ClientMessage::SetRoomOff { room: off_room.clone() });
                    }
                >
                    "OFF"
                </button>
            </div>
            {move || {
                let show = detail_entity.get().as_deref() == Some(display_name.as_str());
                show.then(|| view! {
                    <pre class="json-detail">{json_text.clone()}</pre>
                })
            }}
        </div>
    }
}
