//! Conversion from TASS entities ([`LightZoneEntity`], [`PlugEntity`])
//! to wire DTOs ([`RoomSnapshot`], [`PlugSnapshot`]).

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use mqtt_controller_wire::{
    FullStateSnapshot, HeatingZoneActualValue, HeatingZoneInfo, HeatingZoneSnapshot,
    HeatingZoneTargetValue, KillSwitchRuleInfo, LightActualValue, LightInfo, LightSnapshot,
    MotionMode as WireMotionMode, MotionSensorInfo, PlugActualValue, PlugSnapshot, PlugTargetValue,
    RoomActualValue, RoomInfo, RoomSnapshot, RoomTargetValue, SlotInfo, SwitchActionInfo,
    SwitchButtonInfo, SwitchInfo, TopologyInfo, TrvSnapshot, TrvTargetValue,
};

use crate::entities::heating_zone::{HeatingZoneActual as HzActual, HeatingZoneTarget as HzTarget};
use crate::entities::light::LightEntity;
use crate::entities::light_zone::{LightZoneActual, LightZoneEntity, LightZoneTarget};
use crate::entities::plug::{KillSwitchRuleState, PlugActual, PlugEntity, PlugTarget};
use crate::entities::WorldState;
use crate::logic::EventProcessor;
use crate::topology::{MotionBinding, ResolvedTrigger, Topology};

/// Build a full state snapshot from the processor's current state.
pub fn build_full_snapshot(processor: &EventProcessor, now: Instant) -> FullStateSnapshot {
    let topology = processor.topology();
    let hour = processor.clock().local_hour();
    let minute = processor.clock().local_minute();
    let sun = snapshot_sun_times(processor);
    let epoch_ms = processor.clock().epoch_millis();
    let world = processor.world();

    let rooms: Vec<RoomSnapshot> = topology
        .rooms()
        .map(|room| {
            let zone = world.light_zones.get(&room.name);
            let active_sensors = active_motion_sensors_for_room(processor, &room.name);
            room_snapshot_from(room, zone, &active_sensors, hour, minute, sun.as_ref(), now, processor)
        })
        .collect();

    let plugs: Vec<PlugSnapshot> = topology
        .all_plug_names()
        .iter()
        .map(|&name| plug_snapshot_from(world.plugs.get(name), name, processor, now))
        .collect();

    let heating_zones = build_heating_zone_snapshots(processor, now);
    let lights = build_all_light_snapshots(processor, now);

    FullStateSnapshot {
        rooms,
        plugs,
        heating_zones,
        lights,
        timestamp_epoch_ms: epoch_ms,
    }
}

/// Per-light snapshot builder used for both the full snapshot and
/// incremental `Entity(Light)` updates.
pub fn build_light_snapshot(
    processor: &EventProcessor,
    device: &str,
    now: Instant,
) -> Option<LightSnapshot> {
    // We allow snapshots even for lights that haven't reported yet so
    // the frontend can render their tile in an "unknown" state.
    let topology = processor.topology();
    let device_idx = topology.device_idx(device)?;
    if topology.device_kind(device_idx) != crate::topology::DeviceKind::Light {
        return None;
    }
    let entity = processor.world().lights.get(device);
    let room = light_room_of(topology, device);
    Some(light_snapshot_from(device, room, entity, now))
}

/// Build snapshots for every light in the catalog.
fn build_all_light_snapshots(processor: &EventProcessor, now: Instant) -> Vec<LightSnapshot> {
    let topology = processor.topology();
    let mut out = Vec::new();
    for room in topology.rooms() {
        for member in &room.members {
            let device = member.split('/').next().unwrap_or(member);
            if !topology.is_light(device) {
                continue;
            }
            if out.iter().any(|l: &LightSnapshot| l.device == device) {
                continue;
            }
            let entity = processor.world().lights.get(device);
            out.push(light_snapshot_from(
                device,
                Some(room.name.clone()),
                entity,
                now,
            ));
        }
    }
    out
}

fn light_snapshot_from(
    device: &str,
    room: Option<String>,
    entity: Option<&LightEntity>,
    now: Instant,
) -> LightSnapshot {
    LightSnapshot {
        device: device.to_string(),
        room,
        actual: entity.map(|l| tass_actual_info(&l.actual, now)),
        actual_value: entity.and_then(|l| l.actual.value()).map(light_actual_value),
    }
}

/// Return the room name this light is a member of, if any.
fn light_room_of(topology: &crate::topology::Topology, device: &str) -> Option<String> {
    for room in topology.rooms() {
        for member in &room.members {
            let name = member.split('/').next().unwrap_or(member);
            if name == device {
                return Some(room.name.clone());
            }
        }
    }
    None
}

/// Build a single room snapshot for incremental updates.
pub fn build_room_snapshot(
    processor: &EventProcessor,
    room_name: &str,
    now: Instant,
) -> Option<RoomSnapshot> {
    let topology = processor.topology();
    let room = topology.room_by_name(room_name)?;
    let zone = processor.world().light_zones.get(room_name);
    let hour = processor.clock().local_hour();
    let minute = processor.clock().local_minute();
    let sun = snapshot_sun_times(processor);
    let active_sensors = active_motion_sensors_for_room(processor, room_name);
    Some(room_snapshot_from(room, zone, &active_sensors, hour, minute, sun.as_ref(), now, processor))
}

/// Collect names of motion sensors that are currently active (occupied) for a given room.
fn active_motion_sensors_for_room(processor: &EventProcessor, room_name: &str) -> Vec<String> {
    let Some(room) = processor.topology().room_by_name(room_name) else {
        return Vec::new();
    };
    let world = processor.world();
    room.bound_motion
        .iter()
        .filter(|mb| {
            world
                .motion_sensors
                .get(mb.sensor.as_str())
                .is_some_and(|s| s.is_occupied())
        })
        .map(|mb| mb.sensor.clone())
        .collect()
}

/// Compute sun times for snapshots. Recomputes rather than using
/// EventProcessor's cache because snapshots take `&self` (immutable)
/// while the cache requires `&mut self`. The computation is cheap
/// (~2us) and snapshots are infrequent.
fn snapshot_sun_times(processor: &EventProcessor) -> Option<crate::sun::SunTimes> {
    let loc = processor.location()?;
    let info = processor.clock().local_date_info();
    Some(crate::sun::compute_sun_times(loc, info.date, info.utc_offset_hours))
}

fn room_snapshot_from(
    room: &crate::topology::ResolvedRoom,
    zone: Option<&LightZoneEntity>,
    active_sensors: &[String],
    hour: u8,
    minute: u8,
    sun: Option<&crate::sun::SunTimes>,
    now: Instant,
    processor: &EventProcessor,
) -> RoomSnapshot {
    let (active_slot, scene_ids) = room
        .scenes
        .slot_for_time(hour, minute, sun)
        .map(|(name, slot)| (Some(name.clone()), slot.scene_ids.clone()))
        .unwrap_or((None, Vec::new()));

    let switches = build_room_switches(processor.topology(), &room.name);

    let motion_sensors = build_room_motion_sensors(
        &room.bound_motion,
        processor.world(),
        now,
    );

    let lights = build_room_lights(processor.topology(), room);
    // Reflect the actual gate: cooldown only counts when the last off
    // was motion-driven. Other offs (user press, startup fail-safe,
    // ancestor propagation) don't arm this cooldown.
    let motion_cooldown_remaining_secs = zone
        .and_then(|z| z.last_motion_off_at)
        .and_then(|last_off| {
            let cooldown = Duration::from_secs(room.motion_off_cooldown_seconds as u64);
            let elapsed = now.duration_since(last_off);
            cooldown.checked_sub(elapsed).map(|d| d.as_secs())
        })
        .filter(|&s| s > 0);

    RoomSnapshot {
        name: room.name.clone(),
        group_name: room.group_name.clone(),
        physically_on: zone.map_or(false, |z| z.is_on()),
        motion_owned: zone.map_or(false, |z| z.is_motion_owned()),
        cycle_idx: zone.map_or(0, |z| z.cycle_idx()),
        last_press_ago_ms: zone
            .and_then(|z| z.last_press_at)
            .map(|t| ago_ms(now, t)),
        last_off_ago_ms: zone
            .and_then(|z| z.last_off_at)
            .map(|t| ago_ms(now, t)),
        motion_active_sensors: active_sensors.to_vec(),
        active_slot,
        scene_ids,
        target: zone.map(|z| tass_target_info(&z.target, now)),
        target_value: zone
            .and_then(|z| z.target.value())
            .map(room_target_value),
        actual: zone.map(|z| tass_actual_info(&z.actual, now)),
        actual_value: zone
            .and_then(|z| z.actual.value())
            .map(room_actual_value),
        switches,
        motion_sensors,
        lights,
        motion_off_cooldown_secs: room.motion_off_cooldown_seconds,
        motion_cooldown_remaining_secs,
        motion_mode: wire_motion_mode(room.motion_mode),
    }
}

fn wire_motion_mode(mode: crate::config::MotionMode) -> WireMotionMode {
    match mode {
        crate::config::MotionMode::OnOff => WireMotionMode::OnOff,
        crate::config::MotionMode::OnOnly => WireMotionMode::OnOnly,
        crate::config::MotionMode::OffOnly => WireMotionMode::OffOnly,
    }
}

/// Build a single plug snapshot for incremental updates.
/// Returns `None` if the plug has never been observed.
pub fn build_plug_snapshot(
    processor: &EventProcessor,
    device: &str,
    now: Instant,
) -> Option<PlugSnapshot> {
    let plug = processor.world().plugs.get(device)?;
    Some(plug_snapshot_from(Some(plug), device, processor, now))
}

/// Shared builder used by both `build_full_snapshot` and `build_plug_snapshot`.
/// Accepts `Option<&PlugEntity>` so it can build a placeholder for plugs
/// the daemon has never received state for.
fn plug_snapshot_from(
    plug: Option<&PlugEntity>,
    device: &str,
    processor: &EventProcessor,
    now: Instant,
) -> PlugSnapshot {
    let topology = processor.topology();
    PlugSnapshot {
        device: device.to_string(),
        on: plug.is_some_and(|p| p.is_on()),
        idle_since_ago_ms: processor
            .earliest_kill_switch_idle(device)
            .map(|t| ago_ms(now, t)),
        kill_switch_holdoff_secs: processor.kill_switch_holdoff_secs(device),
        power_watts: plug.and_then(|p| p.power()),
        target: plug.map(|p| tass_target_info(&p.target, now)),
        target_value: plug
            .and_then(|p| p.target.value())
            .map(plug_target_value),
        actual: plug.map(|p| tass_actual_info(&p.actual, now)),
        actual_value: plug
            .and_then(|p| p.actual.value())
            .map(plug_actual_value),
        kill_switch_rules: build_kill_switch_rules(plug, device, topology, now),
        linked_switches: build_linked_switches(topology, device),
    }
}

/// Build topology info for the frontend.
pub fn build_topology_info(topology: &Topology) -> TopologyInfo {
    let rooms: Vec<RoomInfo> = topology
        .rooms()
        .map(|room| RoomInfo {
            name: room.name.clone(),
            group_name: room.group_name.clone(),
            parent: room.parent.clone(),
            slots: room
                .scenes
                .slots
                .iter()
                .map(|(name, slot)| SlotInfo {
                    name: name.clone(),
                    from: slot.from.to_string(),
                    to: slot.to.to_string(),
                    scene_ids: slot.scene_ids.clone(),
                })
                .collect(),
            has_motion: room.has_motion_sensor(),
        })
        .collect();

    let plugs: Vec<String> = topology
        .all_plug_names()
        .iter()
        .map(|&s| s.to_string())
        .collect();

    let heating_zones: Vec<HeatingZoneInfo> = topology
        .heating_config()
        .map(|cfg| {
            cfg.zones
                .iter()
                .map(|zone| HeatingZoneInfo {
                    name: zone.name.clone(),
                    relay_device: zone.relay.clone(),
                    trv_devices: zone.trvs.iter().map(|t| t.device.clone()).collect(),
                })
                .collect()
        })
        .unwrap_or_default();

    TopologyInfo {
        rooms,
        plugs,
        heating_zones,
    }
}

/// Build snapshots for all heating zones.
fn build_heating_zone_snapshots(
    processor: &EventProcessor,
    now: Instant,
) -> Vec<HeatingZoneSnapshot> {
    let Some(heating_cfg) = processor.topology().heating_config() else {
        return Vec::new();
    };
    heating_cfg
        .zones
        .iter()
        .map(|zone| build_one_heating_zone(zone, heating_cfg, processor, now))
        .collect()
}

fn build_one_heating_zone(
    zone: &crate::config::heating::HeatingZone,
    heating_cfg: &crate::config::heating::HeatingConfig,
    processor: &EventProcessor,
    now: Instant,
) -> HeatingZoneSnapshot {
    let hz = processor.world().heating_zones.get(&zone.name);
    let relay_on = hz.is_some_and(|h| h.is_relay_on());
    let relay_state_known = hz.map_or(false, |h| h.relay_state_known);
    let relay_stale = hz.is_some_and(|h| h.is_wt_stale(now));

    let min_cycle = std::time::Duration::from_secs(heating_cfg.heat_pump.min_cycle_seconds);
    let min_pause = std::time::Duration::from_secs(heating_cfg.heat_pump.min_pause_seconds);

    let min_cycle_remaining_secs = processor.effective_pump_on_since()
        .and_then(|on_at| {
            let elapsed = now.duration_since(on_at);
            min_cycle.checked_sub(elapsed)
        })
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let min_pause_remaining_secs = processor.effective_pump_off_since()
        .and_then(|off_at| {
            let elapsed = now.duration_since(off_at);
            min_pause.checked_sub(elapsed)
        })
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let trvs: Vec<TrvSnapshot> = zone
        .trvs
        .iter()
        .map(|zt| {
            let trv = processor.world().trvs.get(&zt.device);
            let schedule_summary = heating_cfg.schedules.get(&zt.schedule)
                .map(|sched| format_schedule_summary(sched))
                .unwrap_or_default();
            let actual = trv.and_then(|t| t.actual.value());
            TrvSnapshot {
                device: zt.device.clone(),
                local_temperature: actual.and_then(|a| a.local_temperature),
                pi_heating_demand: actual.and_then(|a| a.pi_heating_demand),
                running_state: actual
                    .map(|a| {
                        if !a.running_state_seen {
                            "unknown"
                        } else if a.running_state.is_heat() {
                            "heat"
                        } else {
                            "idle"
                        }
                    })
                    .unwrap_or("unknown")
                    .to_string(),
                setpoint: actual.and_then(|a| a.setpoint),
                battery: actual.and_then(|a| a.battery),
                inhibited: trv.is_some_and(|t| t.is_inhibited(now)),
                forced: trv.is_some_and(|t| t.is_forced_open()),
                schedule: zt.schedule.clone(),
                schedule_summary,
                target: trv.map(|t| tass_target_info(&t.target, now)),
                target_value: trv.and_then(|t| t.target.value()).map(trv_target_value),
                actual: trv.map(|t| tass_actual_info(&t.actual, now)),
            }
        })
        .collect();

    HeatingZoneSnapshot {
        name: zone.name.clone(),
        relay_device: zone.relay.clone(),
        relay_on,
        relay_state_known,
        relay_temperature: hz.and_then(|h| h.actual.value()).and_then(|a| a.temperature),
        trvs,
        min_cycle_remaining_secs,
        min_pause_remaining_secs,
        relay_stale,
        target: hz.map(|h| tass_target_info(&h.target, now)),
        target_value: hz.and_then(|h| h.target.value()).map(heating_target_value),
        actual: hz.map(|h| tass_actual_info(&h.actual, now)),
        actual_value: hz.and_then(|h| h.actual.value()).map(heating_actual_value),
    }
}

/// Build a single heating zone snapshot for incremental updates.
pub fn build_heating_zone_snapshot(
    processor: &EventProcessor,
    zone_name: &str,
    now: Instant,
) -> Option<HeatingZoneSnapshot> {
    let heating_cfg = processor.topology().heating_config()?;
    let zone = heating_cfg.zones.iter().find(|z| z.name == zone_name)?;
    Some(build_one_heating_zone(zone, heating_cfg, processor, now))
}

/// Format a schedule as a compact summary string.
/// Uses Monday as representative (all current schedules use allWeek).
/// Format: `"00:00–06:00 → 21°C, 06:00–23:00 → 18°C, 23:00–24:00 → 21°C"`
fn format_schedule_summary(schedule: &crate::config::heating::TemperatureSchedule) -> String {
    use crate::config::heating::Weekday;
    let ranges = match schedule.days.get(&Weekday::Monday) {
        Some(r) => r,
        None => return String::new(),
    };
    ranges
        .iter()
        .map(|r| {
            format!(
                "{:02}:{:02}\u{2013}{:02}:{:02} \u{2192} {:.0}\u{00b0}C",
                r.start_hour, r.start_minute, r.end_hour, r.end_minute, r.temperature
            )
        })
        .collect::<Vec<_>>()
        .join(", ")
}

/// Collect switches bound to a room from the topology's bindings.
fn build_room_switches(topology: &Topology, room_name: &str) -> Vec<SwitchInfo> {
    let room_idx = topology.room_idx(room_name);
    collect_switches(topology, |b| b.effect.room() == room_idx)
}

/// Collect button-trigger switches from bindings that satisfy `pred`,
/// grouped by device. Each device lists its buttons; each button lists
/// every (gesture, effect) action attached.
///
/// Used by both room views (filter bindings by `effect.room()`) and
/// plug views (filter bindings by `effect.target_plug()`).
fn collect_switches(
    topology: &Topology,
    pred: impl Fn(&crate::topology::ResolvedBinding) -> bool,
) -> Vec<SwitchInfo> {
    // device -> button -> [(gesture, description)]
    let mut grouped: BTreeMap<String, BTreeMap<String, Vec<SwitchActionInfo>>> = BTreeMap::new();
    for binding in topology.bindings() {
        if !pred(binding) {
            continue;
        }
        if let ResolvedTrigger::Button {
            device,
            button,
            gesture,
        } = &binding.trigger
        {
            let device_name = topology.device_name(*device).to_string();
            let action = SwitchActionInfo {
                gesture: gesture_label(*gesture),
                description: describe_effect(topology, &binding.effect),
            };
            grouped
                .entry(device_name)
                .or_default()
                .entry(button.clone())
                .or_default()
                .push(action);
        }
    }
    grouped
        .into_iter()
        .map(|(device, buttons)| SwitchInfo {
            device,
            buttons: buttons
                .into_iter()
                .map(|(button, actions)| SwitchButtonInfo { button, actions })
                .collect(),
        })
        .collect()
}

/// Human-readable label for a `Gesture`. Matches the lowercase variants
/// used in the config JSON and in the frontend.
fn gesture_label(g: crate::config::switch_model::Gesture) -> String {
    use crate::config::switch_model::Gesture;
    match g {
        Gesture::Press => "press",
        Gesture::Hold => "hold",
        Gesture::HoldRelease => "hold_release",
        Gesture::DoubleTap => "double_tap",
        Gesture::SoftDoubleTap => "soft_double_tap",
    }
    .to_string()
}

/// One-line description of a resolved effect for the UI popup.
fn describe_effect(
    topology: &Topology,
    effect: &crate::topology::ResolvedEffect,
) -> String {
    use crate::topology::ResolvedEffect;
    let room_name = |r| topology.room(r).name.clone();
    let plug_name = |p: crate::topology::PlugIdx| topology.device_name(p.device()).to_string();
    match effect {
        ResolvedEffect::SceneCycle { room } => format!("scene_cycle → {}", room_name(*room)),
        ResolvedEffect::SceneToggle { room } => format!("scene_toggle → {}", room_name(*room)),
        ResolvedEffect::SceneToggleCycle { room } => {
            format!("scene_toggle_cycle → {}", room_name(*room))
        }
        ResolvedEffect::TurnOffRoom { room } => format!("turn_off → {}", room_name(*room)),
        ResolvedEffect::BrightnessStep { room, step, .. } => {
            format!("brightness_step {step:+} → {}", room_name(*room))
        }
        ResolvedEffect::BrightnessMove { room, rate } => {
            format!("brightness_move {rate:+} → {}", room_name(*room))
        }
        ResolvedEffect::BrightnessStop { room } => {
            format!("brightness_stop → {}", room_name(*room))
        }
        ResolvedEffect::Toggle {
            plug,
            confirm_off_seconds,
        } => match confirm_off_seconds {
            Some(s) => format!("toggle (confirm {s}s) → {}", plug_name(*plug)),
            None => format!("toggle → {}", plug_name(*plug)),
        },
        ResolvedEffect::TurnOn { plug } => format!("turn_on → {}", plug_name(*plug)),
        ResolvedEffect::TurnOff { plug } => format!("turn_off → {}", plug_name(*plug)),
        ResolvedEffect::TurnOffAllZones => "turn_off_all_zones".to_string(),
    }
}

/// Collect the member lights of a room as a flat list of device names.
/// Member strings in the config are `"<friendly_name>/<endpoint>"`; we
/// strip the endpoint and dedup so each light appears once.
fn build_room_lights(
    topology: &Topology,
    room: &crate::topology::ResolvedRoom,
) -> Vec<LightInfo> {
    let mut seen: BTreeMap<String, ()> = BTreeMap::new();
    let mut out = Vec::new();
    for member in &room.members {
        let device = member.split('/').next().unwrap_or(member);
        if seen.contains_key(device) {
            continue;
        }
        // Only surface members that are known lights in the catalog.
        if topology
            .device_idx(device)
            .map(|i| topology.device_kind(i) == crate::topology::DeviceKind::Light)
            .unwrap_or(false)
        {
            seen.insert(device.to_string(), ());
            out.push(LightInfo {
                device: device.to_string(),
            });
        }
    }
    out
}

/// Build motion sensor info for a room from bound motion bindings.
fn build_room_motion_sensors(
    bound_motion: &[MotionBinding],
    world: &WorldState,
    now: Instant,
) -> Vec<MotionSensorInfo> {
    bound_motion
        .iter()
        .map(|mb| {
            let entity = world.motion_sensors.get(&mb.sensor);
            let occupied = entity.and_then(|e| e.actual.value()).map(|a| a.occupied);
            let illuminance = entity.and_then(|e| e.illuminance());
            let freshness = entity
                .map(|e| e.actual.freshness().to_string())
                .unwrap_or_default();
            let since_ago_ms = entity.and_then(|e| e.actual.since()).map(|t| ago_ms(now, t));
            MotionSensorInfo {
                device: mb.sensor.clone(),
                occupied,
                illuminance,
                freshness,
                since_ago_ms,
                occupancy_timeout_secs: mb.occupancy_timeout_seconds,
                max_illuminance: mb.max_illuminance,
            }
        })
        .collect()
}

/// Build kill switch rule info for a plug from its entity state and topology.
fn build_kill_switch_rules(
    plug: Option<&PlugEntity>,
    device: &str,
    topology: &Topology,
    now: Instant,
) -> Vec<KillSwitchRuleInfo> {
    let Some(plug) = plug else {
        return Vec::new();
    };
    let Some(device_idx) = topology.device_idx(device) else {
        return Vec::new();
    };
    topology
        .bindings_for_power_below(device_idx)
        .iter()
        .map(|&idx| {
            let resolved = topology.binding(idx);
            let rule_name = resolved.name.clone();
            let state = plug
                .kill_switch_rules
                .get(&rule_name)
                .cloned()
                .unwrap_or(KillSwitchRuleState::Inactive);
            let (threshold_watts, holdoff_secs) = match &resolved.trigger {
                ResolvedTrigger::PowerBelow { watts, holdoff, .. } => (*watts, holdoff.as_secs()),
                _ => (0.0, 0),
            };
            let idle_since_ago_ms = match &state {
                KillSwitchRuleState::Idle { since } => Some(ago_ms(now, *since)),
                _ => None,
            };
            let state_str = match &state {
                KillSwitchRuleState::Inactive => "inactive",
                KillSwitchRuleState::Armed => "armed",
                KillSwitchRuleState::Idle { .. } => "idle",
                KillSwitchRuleState::Suppressed => "suppressed",
            };
            KillSwitchRuleInfo {
                rule_name,
                state: state_str.to_string(),
                threshold_watts,
                holdoff_secs,
                idle_since_ago_ms,
            }
        })
        .collect()
}

/// Find switches linked to a plug (Button triggers with device-targeting effects).
fn build_linked_switches(topology: &Topology, plug_device: &str) -> Vec<SwitchInfo> {
    let plug_idx = topology.device_idx(plug_device).and_then(|d| topology.plug_idx(d));
    collect_switches(topology, |b| b.effect.target_plug() == plug_idx)
}

fn ago_ms(now: Instant, then: Instant) -> u64 {
    now.duration_since(then).as_millis() as u64
}

/// Convert TASS target lifecycle metadata to its wire shape
/// (phase/owner/since — the typed value lives on the entity snapshot).
fn tass_target_info<T>(
    target: &crate::tass::TassTarget<T>,
    now: Instant,
) -> mqtt_controller_wire::TassTargetInfo {
    mqtt_controller_wire::TassTargetInfo {
        phase: target.phase().to_string(),
        owner: target.owner().map(|o| o.to_string()).unwrap_or_default(),
        since_ago_ms: target.since().map(|t| ago_ms(now, t)),
    }
}

/// Convert TASS actual freshness metadata to its wire shape.
fn tass_actual_info<T>(
    actual: &crate::tass::TassActual<T>,
    now: Instant,
) -> mqtt_controller_wire::TassActualInfo {
    mqtt_controller_wire::TassActualInfo {
        freshness: actual.freshness().to_string(),
        since_ago_ms: actual.since().map(|t| ago_ms(now, t)),
    }
}

// ---------------------------------------------------------------------------
// Typed-value converters: domain TASS values → wire-crate counterparts.
// Kept inline here so `snapshot.rs` owns the whole domain→wire boundary.
// ---------------------------------------------------------------------------

fn room_target_value(t: &LightZoneTarget) -> RoomTargetValue {
    match t {
        LightZoneTarget::Off => RoomTargetValue::Off,
        LightZoneTarget::On {
            scene_id,
            cycle_idx,
        } => RoomTargetValue::On {
            scene_id: *scene_id,
            cycle_idx: *cycle_idx,
        },
    }
}

fn room_actual_value(a: &LightZoneActual) -> RoomActualValue {
    match a {
        LightZoneActual::On => RoomActualValue::On,
        LightZoneActual::Off => RoomActualValue::Off,
    }
}

fn plug_target_value(t: &PlugTarget) -> PlugTargetValue {
    match t {
        PlugTarget::On => PlugTargetValue::On,
        PlugTarget::Off => PlugTargetValue::Off,
    }
}

fn plug_actual_value(a: &PlugActual) -> PlugActualValue {
    PlugActualValue {
        on: a.on,
        power: a.power,
    }
}

fn heating_target_value(t: &HzTarget) -> HeatingZoneTargetValue {
    match t {
        HzTarget::Heating => HeatingZoneTargetValue::Heating,
        HzTarget::Off => HeatingZoneTargetValue::Off,
    }
}

fn heating_actual_value(a: &HzActual) -> HeatingZoneActualValue {
    HeatingZoneActualValue {
        relay_on: a.relay_on,
        temperature: a.temperature,
    }
}

fn light_actual_value(a: &crate::entities::light::LightActual) -> LightActualValue {
    LightActualValue {
        on: a.on,
        brightness: a.brightness,
        color_temp: a.color_temp,
        color_xy: a.color_xy,
    }
}

fn trv_target_value(t: &crate::entities::trv::TrvTarget) -> TrvTargetValue {
    use crate::entities::trv::{ForceOpenReason, TrvTarget};
    match t {
        TrvTarget::Setpoint(temp) => TrvTargetValue::Setpoint {
            temperature: *temp,
        },
        TrvTarget::Inhibited { .. } => TrvTargetValue::Inhibited,
        TrvTarget::ForcedOpen { reason } => TrvTargetValue::ForcedOpen {
            reason: match reason {
                ForceOpenReason::PressureGroup => "pressure_group".to_string(),
                ForceOpenReason::MinCycle => "min_cycle".to_string(),
            },
        },
    }
}

