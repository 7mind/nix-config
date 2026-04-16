//! TASS-based event processor.
//!
//! The processor is the main entry point for the daemon's event loop.
//! It holds the [`WorldState`] (all TASS entities) and dispatches events
//! to per-domain logic modules.
//!
//! ## Module structure
//!
//! Each module handles one domain:
//!   - [`lights`]   — light zone scene cycling, toggle, brightness
//!   - [`motion`]   — motion sensor → light zone automation
//!   - [`plugs`]    — plug state + kill switch evaluation
//!   - [`buttons`]  — button dispatch (double-tap, soft double-tap)
//!   - [`schedule`] — `At` trigger evaluation
//!   - [`heating`]  — heating zones, TRVs, relay control

pub mod buttons;
pub mod heating;
pub mod lights;
pub mod motion;
pub mod plugs;
pub mod schedule;

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::config::Defaults;
use crate::config::heating::HeatingConfig;
use crate::domain::action::Action;
use crate::domain::event::Event;
use crate::entities::WorldState;
use crate::time::Clock;
use crate::topology::Topology;

#[derive(Debug)]
pub struct EventProcessor {
    pub(crate) world: WorldState,
    pub(crate) topology: Arc<Topology>,
    pub(crate) clock: Arc<dyn Clock>,
    pub(crate) defaults: Defaults,
    pub(crate) location: Option<crate::sun::Location>,
    pub(crate) heating_config: Option<HeatingConfig>,

    // Pump tracking (shared across all heating zones)
    pub(crate) pump_on_since: Option<Instant>,
    pub(crate) pump_off_since: Option<Instant>,
    pub(crate) heating_tick_gen: u64,
    pub(crate) startup_complete: bool,
    pub(crate) last_wt_refresh: Option<Instant>,
    pub(crate) ha_last_published: BTreeMap<String, String>,
    pub(crate) ha_discovery_published: bool,

    // Sun cache
    pub(crate) cached_sun: Option<(chrono::NaiveDate, i32, crate::sun::SunTimes)>,
}

impl EventProcessor {
    pub fn new(
        topology: Arc<Topology>,
        clock: Arc<dyn Clock>,
        defaults: Defaults,
        location: Option<crate::sun::Location>,
    ) -> Self {
        let heating_config = topology.heating_config().cloned();
        Self {
            world: WorldState::new(),
            topology,
            clock,
            defaults,
            location,
            heating_config,
            pump_on_since: None,
            pump_off_since: None,
            heating_tick_gen: 0,
            startup_complete: false,
            last_wt_refresh: None,
            ha_last_published: BTreeMap::new(),
            ha_discovery_published: false,
            cached_sun: None,
        }
    }

    /// Single entry point for the daemon's event loop.
    pub fn handle_event(&mut self, event: Event) -> Vec<Action> {
        match event {
            Event::ButtonPress {
                ref device,
                ref button,
                gesture,
                ts,
            } => self.handle_button_press(device, button, gesture, ts),
            Event::Occupancy {
                sensor,
                occupied,
                illuminance,
                ts,
            } => self.handle_occupancy(&sensor, occupied, illuminance, ts),
            Event::GroupState { group, on, ts } => self.handle_group_state(&group, on, ts),
            Event::PlugState {
                device,
                on,
                power,
                ts,
            } => self.handle_plug_state(&device, Some(on), power, ts),
            Event::PlugPowerUpdate {
                device, watts, ts, ..
            } => self.handle_plug_state(&device, None, Some(watts), ts),
            Event::TrvState { .. } | Event::WallThermostatState { .. } => {
                if self.heating_config.is_some() {
                    self.handle_heating_event(&event)
                } else {
                    Vec::new()
                }
            }
            Event::Tick { ts } => self.handle_tick(ts),
        }
    }

    // ----- state accessors ---------------------------------------------------

    /// Read-only access to the world state.
    pub fn world(&self) -> &WorldState {
        &self.world
    }

    /// Mutable access to the world state.
    pub fn world_mut(&mut self) -> &mut WorldState {
        &mut self.world
    }

    /// Reference to the immutable topology.
    pub fn topology(&self) -> &Arc<Topology> {
        &self.topology
    }

    /// Reference to the clock.
    pub fn clock(&self) -> &Arc<dyn Clock> {
        &self.clock
    }

    /// Earliest deadline among pending presses, if any.
    pub fn next_press_deadline(&self) -> Option<Instant> {
        self.world.next_press_deadline()
    }

    /// Reference to the geographic location (if configured).
    pub fn location(&self) -> Option<&crate::sun::Location> {
        self.location.as_ref()
    }

    // ----- startup helpers ---------------------------------------------------

    /// Set the physical state of a light zone from a retained MQTT message.
    pub fn set_zone_actual(&mut self, room: &str, on: bool, ts: Instant) {
        use crate::entities::light_zone::LightZoneActual;
        let zone = self.world.light_zone(room);
        let actual = if on {
            LightZoneActual::On
        } else {
            LightZoneActual::Off
        };
        zone.actual.update(actual, ts);
    }

    /// Set the physical state of a plug from a retained MQTT message.
    pub fn set_plug_actual(&mut self, device: &str, on: bool, power: Option<f64>, ts: Instant) {
        use crate::entities::plug::PlugActual;
        let plug = self.world.plug(device);
        plug.actual.update(PlugActual { on, power }, ts);
    }

    /// Turn off all motion-controlled rooms that are physically on at startup.
    pub fn startup_turn_off_motion_zones(&mut self, ts: Instant) -> Vec<Action> {
        use crate::domain::action::Payload;
        use crate::entities::light_zone::{LightZoneActual, LightZoneTarget};
        use crate::tass::Owner;

        let mut out = Vec::new();
        for room in self.topology.rooms() {
            let zone = self.world.light_zone(&room.name);
            if !zone.actual_is_on() {
                continue;
            }
            if room.has_motion_sensor() {
                tracing::info!(
                    room = %room.name,
                    group = %room.group_name,
                    transition = room.off_transition_seconds,
                    "startup: turning off motion-controlled zone (no cooldown)"
                );
                zone.target
                    .set_and_command(LightZoneTarget::Off, Owner::System, ts);
                // Deliberate TASS bypass: fabricate actual=Off at startup so
                // motion sensors can immediately re-trigger if someone is in
                // the room. Without this, actual stays On (from retained echo)
                // and motion-on gates block.
                zone.actual.update(LightZoneActual::Off, ts);
                out.push(Action::new(
                    &room.group_name,
                    Payload::state_off(room.off_transition_seconds),
                ));
            } else {
                tracing::info!(
                    room = %room.name,
                    "startup: room is physically on; leaving user-owned (no motion sensor)"
                );
            }
        }
        out
    }

    /// Pre-arm kill switch rules for all plugs that are currently ON.
    /// Delegates to the shared per-plug arming helper used by the
    /// runtime off→on path; only the log messages differ.
    pub fn arm_kill_switches_for_active_plugs(&mut self, ts: Instant) {
        let active: Vec<(String, Option<f64>)> = self.world.plugs.iter()
            .filter(|(_, p)| p.actual.value().is_some_and(|a| a.on))
            .map(|(name, p)| (name.clone(), p.power()))
            .collect();
        for (device, power) in active {
            self.arm_kill_switch_rules(&device, power, ts, crate::logic::plugs::ArmCause::Startup);
        }
    }

    // ----- web command handlers ----------------------------------------------

    /// Web UI: recall a specific scene in a room.
    pub fn web_recall_scene(&mut self, room_name: &str, scene_id: u8, ts: Instant) -> Vec<Action> {
        use crate::domain::action::Payload;
        use crate::entities::light_zone::LightZoneTarget;
        use crate::tass::Owner;

        let scenes_for_now = self.scenes_for_room(room_name);
        let Some(room) = self.topology.room_by_name(room_name) else {
            return Vec::new();
        };
        let group_name = room.group_name.clone();

        let cycle_idx = scenes_for_now
            .iter()
            .position(|&id| id == scene_id)
            .unwrap_or(0);

        tracing::info!(
            room = room_name,
            group = %group_name,
            scene = scene_id,
            cycle_idx,
            "web: recall scene"
        );

        let action = Action::new(group_name, Payload::scene_recall(scene_id));
        let zone = self.world.light_zone(room_name);
        zone.target.set_and_command(
            LightZoneTarget::On {
                scene_id,
                cycle_idx,
            },
            Owner::WebUI,
            ts,
        );
        zone.last_press_at = Some(ts);
        self.propagate_to_descendants(room_name, true, ts);
        vec![action]
    }

    /// Web UI: turn a room off.
    pub fn web_set_room_off(&mut self, room_name: &str, ts: Instant) -> Vec<Action> {
        use crate::tass::Owner;
        let Some(room) = self.topology.room_by_name(room_name) else {
            return Vec::new();
        };
        let group_name = room.group_name.clone();
        let off_transition = room.off_transition_seconds;

        tracing::info!(
            room = room_name,
            group = %group_name,
            transition = off_transition,
            "web: set room off"
        );

        let mut out = Vec::new();
        self.publish_off(room_name, &group_name, off_transition, ts, &mut out, Owner::WebUI);
        out
    }

    /// Web UI: toggle a smart plug.
    pub fn web_toggle_plug(&mut self, device: &str, ts: Instant) -> Vec<Action> {
        use crate::domain::action::Payload;
        use crate::entities::plug::PlugTarget;
        use crate::tass::Owner;

        if !self.topology.is_plug(device) {
            tracing::warn!(device, "web: toggle plug rejected — unknown device");
            return Vec::new();
        }
        let is_on = self.world.plugs.get(device).is_some_and(|p| p.is_on());
        let (new_target, payload) = if is_on {
            (PlugTarget::Off, Payload::device_off())
        } else {
            (PlugTarget::On, Payload::device_on())
        };
        let plug = self.world.plug(device);
        plug.target.set_and_command(new_target, Owner::WebUI, ts);

        tracing::info!(device, target_state = !is_on, "web: toggle plug");
        vec![Action::for_device(device, payload)]
    }

    // ----- tick handler ------------------------------------------------------

    fn handle_tick(&mut self, ts: Instant) -> Vec<Action> {
        let mut out = self.flush_pending_presses(ts);
        out.extend(self.evaluate_at_triggers(ts));
        out.extend(self.evaluate_kill_switch_ticks(ts));
        self.evaluate_target_staleness(ts);
        out.extend(self.evaluate_actual_staleness(ts));

        if self.heating_config.is_some() {
            out.extend(self.handle_heating_tick());
        }

        out
    }

    // ----- target staleness --------------------------------------------------

    /// Threshold for marking a Commanded target as Stale.
    /// z2m echoes normally arrive within 1-2 seconds; 10s is generous.
    const TARGET_STALE_THRESHOLD: Duration = Duration::from_secs(10);

    /// Check all TASS entities for stuck Commanded targets and mark them
    /// Stale if confirmation hasn't arrived within the threshold.
    fn evaluate_target_staleness(&mut self, now: Instant) {
        // Wall thermostats respond slower than lights, so heating zones
        // get a longer window.
        const HEATING_TARGET_STALE_THRESHOLD: Duration = Duration::from_secs(60);
        let msg = "target stale: no confirmation within threshold";
        for (name, zone) in &mut self.world.light_zones {
            if zone.target.mark_stale_if_old(now, Self::TARGET_STALE_THRESHOLD) {
                tracing::info!(room = name.as_str(), "{msg}");
            }
        }
        for (name, plug) in &mut self.world.plugs {
            if plug.target.mark_stale_if_old(now, Self::TARGET_STALE_THRESHOLD) {
                tracing::info!(plug = name.as_str(), "{msg}");
            }
        }
        for (name, zone) in &mut self.world.heating_zones {
            if zone.target.mark_stale_if_old(now, HEATING_TARGET_STALE_THRESHOLD) {
                tracing::info!(zone = name.as_str(), "heating zone target stale: no relay confirmation within threshold");
            }
        }
    }

    /// Motion sensors report every ~10-30s (temperature/battery updates).
    /// If no update arrives for 2 minutes, the sensor may be offline.
    const MOTION_SENSOR_STALE_THRESHOLD: Duration = Duration::from_secs(120);

    /// Plugs with power monitoring report every few seconds when on.
    /// 10 minutes without any update is suspicious.
    const PLUG_ACTUAL_STALE_THRESHOLD: Duration = Duration::from_secs(600);

    /// Age actual state freshness for entities that have expected
    /// periodic reporting. Light zones are NOT aged because z2m only
    /// publishes group state on changes — a stable group can go hours
    /// without an update and that's normal.
    ///
    /// When a motion sensor goes stale, re-evaluates motion-owned rooms
    /// to trigger motion-off if the stale sensor was the last occupied
    /// sensor in its room.
    fn evaluate_actual_staleness(&mut self, now: Instant) -> Vec<Action> {
        let mut newly_stale_sensors = Vec::new();
        for (name, sensor) in &mut self.world.motion_sensors {
            if sensor.actual.mark_stale_if_old(now, Self::MOTION_SENSOR_STALE_THRESHOLD) {
                tracing::info!(sensor = name.as_str(), "motion sensor actual stale — treating as not occupied");
                newly_stale_sensors.push(name.clone());
            }
        }
        for (name, plug) in &mut self.world.plugs {
            if plug.actual.mark_stale_if_old(now, Self::PLUG_ACTUAL_STALE_THRESHOLD) {
                tracing::debug!(plug = name.as_str(), "plug actual stale");
            }
        }

        // Re-evaluate motion-off for rooms affected by newly stale sensors.
        // A sensor going stale while occupied=true means is_occupied() now
        // returns false, so if all other sensors are also inactive/stale,
        // the motion-owned room should turn off.
        let mut actions = Vec::new();
        for sensor_name in newly_stale_sensors {
            let rooms: Vec<String> = self
                .topology
                .rooms_for_motion(&sensor_name)
                .to_vec();
            for room_name in &rooms {
                let zone = self.world.light_zones.get(room_name);
                let is_motion_owned = zone.is_some_and(|z| z.is_motion_owned());
                let is_on = zone.is_some_and(|z| z.is_on());
                if !is_motion_owned || !is_on {
                    continue;
                }
                // Check if ALL sensors for this room are now inactive/stale.
                let all_inactive = self
                    .topology
                    .room_by_name(room_name)
                    .map_or(true, |room| {
                        room.bound_motion.iter().all(|bm| {
                            !self
                                .world
                                .motion_sensors
                                .get(&bm.sensor)
                                .is_some_and(|s| s.is_occupied())
                        })
                    });
                if all_inactive {
                    if let Some(room) = self.topology.room_by_name(room_name) {
                        let group_name = room.group_name.clone();
                        let off_transition = room.off_transition_seconds;
                        tracing::info!(
                            room = room_name.as_str(),
                            sensor = sensor_name.as_str(),
                            "stale sensor triggered motion-off (all sensors inactive/stale)"
                        );
                        actions.push(Action::new(
                            group_name,
                            crate::domain::action::Payload::state_off(off_transition),
                        ));
                        // Only set target — do NOT fabricate actual=Off.
                        // Actual state updates come from z2m group echoes
                        // (handle_group_state). If the OFF command is lost,
                        // actual stays On and the mismatch is visible.
                        let zone = self.world.light_zone(room_name);
                        zone.target.set_and_command(
                            crate::entities::light_zone::LightZoneTarget::Off,
                            crate::tass::Owner::System,
                            now,
                        );
                    }
                }
            }
        }
        actions
    }

    // ----- sun time helpers --------------------------------------------------

    pub(crate) fn sun_times(&mut self) -> Option<crate::sun::SunTimes> {
        let loc = self.location.as_ref()?;
        let info = self.clock.local_date_info();
        let offset_secs = (info.utc_offset_hours * 3600.0) as i32;
        let needs_refresh = self.cached_sun.as_ref().map_or(true, |(d, o, _)| {
            *d != info.date || *o != offset_secs
        });
        if needs_refresh {
            let times = crate::sun::compute_sun_times(loc, info.date, info.utc_offset_hours);
            tracing::info!(
                sunrise = %format!("{:02}:{:02}", times.sunrise_minute_of_day / 60, times.sunrise_minute_of_day % 60),
                sunset = %format!("{:02}:{:02}", times.sunset_minute_of_day / 60, times.sunset_minute_of_day % 60),
                date = %info.date,
                offset_secs,
                "computed sun times"
            );
            self.cached_sun = Some((info.date, offset_secs, times));
        }
        self.cached_sun.as_ref().map(|(_, _, t)| *t)
    }

    pub(crate) fn scenes_for_room(&mut self, room_name: &str) -> Vec<u8> {
        let sun = self.sun_times();
        let hour = self.clock.local_hour();
        let minute = self.clock.local_minute();
        let Some(room) = self.topology.room_by_name(room_name) else {
            return Vec::new();
        };
        room.scenes.active_slot_scene_ids(hour, minute, sun.as_ref())
    }
}
