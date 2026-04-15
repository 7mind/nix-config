//! Conversion from TASS entities ([`LightZoneEntity`], [`PlugEntity`])
//! to wire DTOs ([`RoomSnapshot`], [`PlugSnapshot`]).

use std::time::Instant;

use mqtt_controller_wire::{
    ActionDto, FullStateSnapshot, HeatingZoneInfo, HeatingZoneSnapshot, KillSwitchRuleInfo,
    MotionSensorInfo, PlugSnapshot, RoomInfo, RoomSnapshot, SlotInfo, SwitchInfo, TopologyInfo,
    TrvSnapshot,
};

use crate::config::Trigger;
use crate::domain::action::{Action, ActionTarget};
use crate::entities::light_zone::LightZoneEntity;
use crate::entities::plug::{KillSwitchRuleState, PlugEntity};
use crate::entities::WorldState;
use crate::logic::EventProcessor;
use crate::topology::{MotionBinding, Topology};

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
        .map(|name| {
            let plug = world.plugs.get(name);
            let idle_since_ago_ms = processor
                .earliest_kill_switch_idle(name)
                .map(|t| ago_ms(now, t));
            let kill_switch_holdoff_secs = processor.kill_switch_holdoff_secs(name);
            let kill_switch_rules = build_kill_switch_rules(plug, name, topology, now);
            let linked_switches = build_linked_switches(topology, name);
            PlugSnapshot {
                device: name.clone(),
                on: plug.map_or(false, |p| p.is_on()),
                idle_since_ago_ms,
                kill_switch_holdoff_secs,
                power_watts: plug.and_then(|p| p.power()),
                target: plug.map(|p| tass_target_info(&p.target, now)),
                actual: plug.map(|p| tass_actual_info(&p.actual, now)),
                kill_switch_rules,
                linked_switches,
            }
        })
        .collect();

    let heating_zones = build_heating_zone_snapshots(processor, now);

    FullStateSnapshot {
        rooms,
        plugs,
        heating_zones,
        timestamp_epoch_ms: epoch_ms,
    }
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
        actual: zone.map(|z| tass_actual_info(&z.actual, now)),
        switches,
        motion_sensors,
    }
}

/// Build a single plug snapshot for incremental updates.
pub fn build_plug_snapshot(
    processor: &EventProcessor,
    device: &str,
    now: Instant,
) -> Option<PlugSnapshot> {
    let plug = processor.world().plugs.get(device)?;
    let idle_since_ago_ms = processor
        .earliest_kill_switch_idle(device)
        .map(|t| ago_ms(now, t));
    let kill_switch_holdoff_secs = processor.kill_switch_holdoff_secs(device);
    let topology = processor.topology();
    let kill_switch_rules = build_kill_switch_rules(Some(plug), device, topology, now);
    let linked_switches = build_linked_switches(topology, device);
    Some(PlugSnapshot {
        device: device.to_string(),
        on: plug.is_on(),
        idle_since_ago_ms,
        kill_switch_holdoff_secs,
        power_watts: plug.power(),
        target: Some(tass_target_info(&plug.target, now)),
        actual: Some(tass_actual_info(&plug.actual, now)),
        kill_switch_rules,
        linked_switches,
    })
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

    let plugs: Vec<String> = topology.all_plug_names().iter().cloned().collect();

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

/// Convert an [`Action`] to a wire DTO.
pub fn action_to_dto(action: &Action) -> ActionDto {
    let (target_kind, target) = match &action.target {
        ActionTarget::Group(name) => ("group", name.as_str()),
        ActionTarget::Device(name) => ("device", name.as_str()),
        ActionTarget::DeviceGet(name) => ("device_get", name.as_str()),
        ActionTarget::Raw { topic, .. } => ("raw", topic.as_str()),
    };
    ActionDto {
        target: target.to_string(),
        target_kind: target_kind.to_string(),
        payload_json: serde_json::to_string(&action.payload).unwrap_or_default(),
    }
}

/// Summarize an event for the decision log.
pub fn summarize_event(event: &crate::domain::event::Event) -> String {
    match event {
        crate::domain::event::Event::ButtonPress {
            device, button, gesture, ..
        } => format!("button {gesture:?} {button} on {device}"),
        crate::domain::event::Event::Occupancy {
            sensor,
            occupied,
            illuminance,
            ..
        } => {
            let lux = illuminance
                .map(|l| format!(", lux={l}"))
                .unwrap_or_default();
            let state = if *occupied { "active" } else { "inactive" };
            format!("motion {state} on {sensor}{lux}")
        }
        crate::domain::event::Event::GroupState { group, on, .. } => {
            let state = if *on { "ON" } else { "OFF" };
            format!("group state {state} for {group}")
        }
        crate::domain::event::Event::PlugState {
            device, on, power, ..
        } => {
            let state = if *on { "ON" } else { "OFF" };
            let watts = power
                .map(|w| format!(", {w:.1}W"))
                .unwrap_or_default();
            format!("plug state {state} for {device}{watts}")
        }
        crate::domain::event::Event::PlugPowerUpdate {
            device, watts, ..
        } => {
            format!("plug power {watts:.1}W for {device}")
        }
        crate::domain::event::Event::TrvState {
            device,
            local_temperature,
            pi_heating_demand,
            running_state,
            ..
        } => {
            let temp = local_temperature
                .map(|t| format!("{t:.1}°C"))
                .unwrap_or_else(|| "?".into());
            let demand = pi_heating_demand
                .map(|d| format!("{d}%"))
                .unwrap_or_else(|| "?".into());
            let rs = running_state.as_deref().unwrap_or("?");
            format!("trv {device}: {temp}, demand {demand}, {rs}")
        }
        crate::domain::event::Event::WallThermostatState {
            device, relay_on, ..
        } => {
            let state = relay_on
                .map(|on| if on { "ON" } else { "OFF" })
                .unwrap_or("?");
            format!("wall thermostat {device}: relay {state}")
        }
        crate::domain::event::Event::Tick { .. } => "tick".to_string(),
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
    let Some(heating_state) = processor.heating_state() else {
        return Vec::new();
    };
    heating_cfg
        .zones
        .iter()
        .map(|zone| build_one_heating_zone(zone, heating_cfg, heating_state, now))
        .collect()
}

fn build_one_heating_zone(
    zone: &crate::config::heating::HeatingZone,
    heating_cfg: &crate::config::heating::HeatingConfig,
    heating_state: &crate::domain::heating_state::HeatingRuntimeState,
    now: Instant,
) -> HeatingZoneSnapshot {
    let zone_state = heating_state.zones.get(&zone.name);
    let relay_on = zone_state.map_or(false, |z| z.relay_on);
    let relay_state_known = zone_state.map_or(false, |z| z.relay_state_known);
    let relay_stale = zone_state.map_or(false, |z| z.is_wt_stale(now));

    // Compute pump protection remaining times.
    let min_cycle = std::time::Duration::from_secs(heating_cfg.heat_pump.min_cycle_seconds);
    let min_pause = std::time::Duration::from_secs(heating_cfg.heat_pump.min_pause_seconds);

    let min_cycle_remaining_secs = heating_state.effective_pump_on_since()
        .and_then(|on_at| {
            let elapsed = now.duration_since(on_at);
            min_cycle.checked_sub(elapsed)
        })
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let min_pause_remaining_secs = heating_state.effective_pump_off_since()
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
            let trv_state = zone_state.and_then(|z| z.trvs.get(&zt.device));
            let schedule_summary = heating_cfg.schedules.get(&zt.schedule)
                .map(|sched| format_schedule_summary(sched))
                .unwrap_or_default();
            TrvSnapshot {
                device: zt.device.clone(),
                local_temperature: trv_state.and_then(|t| t.local_temperature),
                pi_heating_demand: trv_state.and_then(|t| t.pi_heating_demand),
                running_state: trv_state
                    .map(|t| {
                        if !t.running_state_seen {
                            "unknown"
                        } else if t.running_state.is_heat() {
                            "heat"
                        } else {
                            "idle"
                        }
                    })
                    .unwrap_or("unknown")
                    .to_string(),
                setpoint: trv_state.and_then(|t| t.reported_setpoint),
                battery: trv_state.and_then(|t| t.battery),
                inhibited: trv_state.is_some_and(|t| t.is_inhibited(now)),
                forced: trv_state.is_some_and(|t| t.pressure_forced || t.min_cycle_forced),
                schedule: zt.schedule.clone(),
                schedule_summary,
            }
        })
        .collect();

    HeatingZoneSnapshot {
        name: zone.name.clone(),
        relay_device: zone.relay.clone(),
        relay_on,
        relay_state_known,
        relay_temperature: None,
        trvs,
        min_cycle_remaining_secs,
        min_pause_remaining_secs,
        relay_stale,
    }
}

/// Build a single heating zone snapshot for incremental updates.
pub fn build_heating_zone_snapshot(
    processor: &EventProcessor,
    zone_name: &str,
    now: Instant,
) -> Option<HeatingZoneSnapshot> {
    let heating_cfg = processor.topology().heating_config()?;
    let heating_state = processor.heating_state()?;
    let zone = heating_cfg.zones.iter().find(|z| z.name == zone_name)?;
    Some(build_one_heating_zone(zone, heating_cfg, heating_state, now))
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

/// Extract entity names from an event (before it is consumed by handle_event).
pub fn extract_event_entities(
    event: &crate::domain::event::Event,
    topology: &Topology,
) -> Vec<String> {
    let mut entities = Vec::new();
    match event {
        crate::domain::event::Event::ButtonPress {
            device, button, gesture, ..
        } => {
            entities.push(device.clone());
            // Derive related rooms from bindings for this button event.
            for &idx in topology.bindings_for_button(device, button, *gesture) {
                let binding = &topology.bindings()[idx];
                if let Some(room) = binding.effect.room() {
                    entities.push(room.to_string());
                }
            }
        }
        crate::domain::event::Event::Occupancy { sensor, .. } => {
            entities.push(sensor.clone());
            for room in topology.rooms_for_motion(sensor) {
                entities.push(room.clone());
            }
        }
        crate::domain::event::Event::GroupState { group, .. } => {
            entities.push(group.clone());
            if let Some(room) = topology.room_by_group_name(group) {
                entities.push(room.name.clone());
            }
        }
        crate::domain::event::Event::PlugState { device, .. }
        | crate::domain::event::Event::PlugPowerUpdate { device, .. } => {
            entities.push(device.clone());
        }
        crate::domain::event::Event::TrvState { device, .. } => {
            entities.push(device.clone());
            if let Some(cfg) = topology.heating_config() {
                for zone in &cfg.zones {
                    if zone.trvs.iter().any(|t| t.device == *device) {
                        entities.push(zone.name.clone());
                    }
                }
            }
        }
        crate::domain::event::Event::WallThermostatState { device, .. } => {
            entities.push(device.clone());
            if let Some(cfg) = topology.heating_config() {
                for zone in &cfg.zones {
                    if zone.relay == *device {
                        entities.push(zone.name.clone());
                    }
                }
            }
        }
        crate::domain::event::Event::Tick { .. } => {}
    }
    entities
}

/// Combine event entities with action-target entities into a deduped list.
pub fn finish_involved_entities(
    mut entities: Vec<String>,
    actions: &[crate::domain::action::Action],
    topology: &Topology,
) -> Vec<String> {
    for action in actions {
        let target_name = match &action.target {
            crate::domain::action::ActionTarget::Group(name) => name,
            crate::domain::action::ActionTarget::Device(name) => name,
            crate::domain::action::ActionTarget::DeviceGet(name) => name,
            crate::domain::action::ActionTarget::Raw { .. } => continue,
        };
        entities.push(target_name.clone());
        if let crate::domain::action::ActionTarget::Group(group) = &action.target {
            if let Some(room) = topology.room_by_group_name(group) {
                entities.push(room.name.clone());
            }
        }
    }
    entities.sort();
    entities.dedup();
    entities
}

/// Collect switches bound to a room from the topology's bindings.
fn build_room_switches(topology: &Topology, room_name: &str) -> Vec<SwitchInfo> {
    let mut switches = Vec::new();
    for binding in topology.bindings() {
        if binding.effect.room() != Some(room_name) {
            continue;
        }
        if let Trigger::Button { device, button, .. } = &binding.trigger {
            // Dedup: avoid duplicates when multiple gestures bind the
            // same (device, button) to the same room.
            if !switches.iter().any(|s: &SwitchInfo| s.device == *device && s.button == *button) {
                switches.push(SwitchInfo {
                    device: device.clone(),
                    button: button.clone(),
                    last_event: None,
                });
            }
        }
    }
    switches
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
    topology
        .bindings_for_power_below(device)
        .iter()
        .map(|&idx| {
            let resolved = &topology.bindings()[idx];
            let rule_name = resolved.name.clone();
            let state = plug
                .kill_switch_rules
                .get(&rule_name)
                .cloned()
                .unwrap_or(KillSwitchRuleState::Inactive);
            let (threshold_watts, holdoff_secs) = match &resolved.trigger {
                Trigger::PowerBelow { watts, for_seconds, .. } => (*watts, *for_seconds),
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
    let mut switches = Vec::new();
    for binding in topology.bindings() {
        if binding.effect.target() != Some(plug_device) {
            continue;
        }
        if let Trigger::Button { device, button, .. } = &binding.trigger {
            if !switches.iter().any(|s: &SwitchInfo| s.device == *device && s.button == *button) {
                switches.push(SwitchInfo {
                    device: device.clone(),
                    button: button.clone(),
                    last_event: None,
                });
            }
        }
    }
    switches
}

fn ago_ms(now: Instant, then: Instant) -> u64 {
    now.duration_since(then).as_millis() as u64
}

/// Convert a TASS target to a wire DTO.
fn tass_target_info<T: std::fmt::Debug>(
    target: &crate::tass::TassTarget<T>,
    now: Instant,
) -> mqtt_controller_wire::TassTargetInfo {
    mqtt_controller_wire::TassTargetInfo {
        value: target
            .value()
            .map(|v| format!("{v:?}"))
            .unwrap_or_default(),
        phase: target.phase().to_string(),
        owner: target
            .owner()
            .map(|o| o.to_string())
            .unwrap_or_default(),
        since_ago_ms: target.since().map(|t| ago_ms(now, t)),
    }
}

/// Convert a TASS actual to a wire DTO.
fn tass_actual_info<T: std::fmt::Debug>(
    actual: &crate::tass::TassActual<T>,
    now: Instant,
) -> mqtt_controller_wire::TassActualInfo {
    mqtt_controller_wire::TassActualInfo {
        value: actual
            .value()
            .map(|v| format!("{v:?}"))
            .unwrap_or_default(),
        freshness: actual.freshness().to_string(),
        since_ago_ms: actual.since().map(|t| ago_ms(now, t)),
    }
}

