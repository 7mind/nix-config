//! The runtime controller. Holds the immutable [`Topology`] and the
//! mutable per-zone [`ZoneState`] map. One entry point —
//! [`Controller::handle_event`] — that the daemon's main loop calls for
//! every incoming MQTT message.
//!
//! Pure-ish:
//!
//!   * It mutates `self` (the in-memory state map). The daemon owns the
//!     only copy, so this is fine for the controller's serial event loop.
//!   * It reads "now" from a [`Clock`]. Tests inject a [`FakeClock`].
//!   * It does NOT touch MQTT or any other I/O. Side effects flow OUT
//!     via the returned `Vec<Action>`.
//!
//! ## Module structure
//!
//! Handler logic is split by concern:
//!
//!   * [`room`]    — wall-switch and tap-button scene cycling
//!   * [`motion`]  — motion-sensor dispatch (occupancy gating,
//!     multi-sensor OR-gate, illuminance gate, cooldown)
//!   * [`plug`]    — plug state tracking and kill-switch integration
//!   * [`actions`] — action-rule dispatch (trigger matching, effect
//!     execution, confirm-off toggle, scheduled `At` triggers)
//!   * [`kill_switch`] — the kill-switch evaluator: power-below
//!     threshold monitoring with holdoff, arming, and warmup
//!     suppression (extracted from the controller to eliminate
//!     duplicated evaluation between `handle_plug_state` and
//!     `handle_tick`)
//!
//! Group-state reconciliation is small enough to live here in `mod.rs`.
//!
//! ## State machine summary
//!
//! For every room, we keep a [`ZoneState`] holding:
//!   - `physically_on`  — last known physical state (refreshed from
//!     `zigbee2mqtt/<group>` retained messages on startup, then updated
//!     every time we publish or receive a group state)
//!   - `cycle_idx`      — index into the active slot's cycle list
//!   - `last_press_at`  — Instant of the room's most recent cycle press
//!     (used by the cycle window comparison)
//!   - `motion_owned`   — true if the lights were turned on by motion
//!     (only motion-on can transition to motion-off; user presses clear
//!     this flag)
//!   - `motion_active_by_sensor` — per-sensor occupancy flags (multi-
//!     sensor OR-gate so motion-off only fires when *every* sensor is
//!     idle)
//!   - `last_off_at`    — Instant of the most recent OFF (motion
//!     cooldown gate)

pub mod heating;
pub mod kill_switch;

mod actions;
mod motion;
mod plug;
mod room;

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Instant;

use crate::config::Defaults;
use crate::domain::action::{Action, Payload};
use crate::domain::event::Event;
use crate::domain::state::{PlugRuntimeState, ZoneState};
use crate::time::Clock;
use crate::topology::{RoomName, Topology};

use heating::HeatingController;
use kill_switch::KillSwitchEvaluator;

// ## Why wall switch on and tap press take different code paths
//
// Wall switches have a dedicated `off_press_release` button. The
// `on_press_release` button is then a pure "scene cycle" button: every
// press advances the active slot's cycle by one, indefinitely, with no
// time component at all. The cycle index only resets when the lights
// physically go off (via the dedicated off button, an external action,
// or `cycle_idx = 0` reseed in `handle_group_state`).
//
// Tap remotes only have four buttons total — burning one per room for
// "off" would waste the device. So the same tap button does triple
// duty: fresh-on when off, cycle-next within a window, expire-to-off
// after the window. The window matters because it's the only way the
// device can distinguish "I want the next scene" from "I want it off".
//
// Both kinds share `defaults.cycle_window_seconds`, but that knob is
// only meaningful for taps. For wall switches it's ignored.

#[derive(Debug)]
pub struct Controller {
    topology: Arc<Topology>,
    clock: Arc<dyn Clock>,
    defaults: Defaults,

    /// Per-room state. Initialized lazily on first access.
    states: BTreeMap<RoomName, ZoneState>,

    /// Per-plug runtime state, keyed by plug friendly_name.
    plug_states: BTreeMap<String, PlugRuntimeState>,

    /// Kill-switch evaluator — owns arming, idle tracking, and
    /// warmup suppression state for all `PowerBelow` action rules.
    kill_switch: KillSwitchEvaluator,

    /// Pending confirm-off timestamps, keyed by action rule name.
    confirm_off_pending: BTreeMap<String, Instant>,

    /// Last (hour, minute) at which each `At` trigger fired, keyed by
    /// action rule name.
    at_last_fired: BTreeMap<String, (u8, u8)>,

    /// Optional heating sub-controller. Only present when the config
    /// has a `heating` section.
    heating: Option<HeatingController>,

    /// Geographic location for sunrise/sunset. `None` when no schedule
    /// uses sun-relative expressions.
    location: Option<crate::sun::Location>,

    /// Cached sunrise/sunset. Keyed by (date, utc_offset_seconds) so
    /// a DST transition within the same date forces a recompute.
    cached_sun: Option<(chrono::NaiveDate, i32, crate::sun::SunTimes)>,
}

impl Controller {
    pub fn new(
        topology: Arc<Topology>,
        clock: Arc<dyn Clock>,
        defaults: Defaults,
        location: Option<crate::sun::Location>,
    ) -> Self {
        let kill_switch = KillSwitchEvaluator::new(topology.clone());
        let heating = topology
            .heating_config()
            .cloned()
            .map(|cfg| HeatingController::new(cfg, topology.clone(), clock.clone()));
        Self {
            topology,
            clock,
            defaults,
            states: BTreeMap::new(),
            plug_states: BTreeMap::new(),
            kill_switch,
            confirm_off_pending: BTreeMap::new(),
            at_last_fired: BTreeMap::new(),
            heating,
            location,
            cached_sun: None,
        }
    }

    /// Single entry point for the daemon's event loop.
    pub fn handle_event(&mut self, event: Event) -> Vec<Action> {
        match event {
            Event::SwitchAction {
                ref device,
                action,
                ts,
            } => {
                let mut out = self.handle_switch_action(device, action, ts);
                out.extend(self.dispatch_switch_actions(device, action, ts));
                out
            }
            Event::TapAction {
                ref device,
                button,
                ref action,
                ts,
            } => {
                let mut out = self.handle_tap_action(device, button, action.as_deref(), ts);
                out.extend(self.dispatch_tap_actions(device, button, action.as_deref(), ts));
                out
            }
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
                device,
                watts,
                ts,
            } => self.handle_plug_state(&device, None, Some(watts), ts),
            Event::TrvState { .. } => {
                if let Some(ref mut hc) = self.heating {
                    hc.handle_event(&event)
                } else {
                    Vec::new()
                }
            }
            Event::WallThermostatState { .. } => {
                if let Some(ref mut hc) = self.heating {
                    hc.handle_event(&event)
                } else {
                    Vec::new()
                }
            }
            Event::Tick { ts } => self.handle_tick(ts),
        }
    }

    // ----- state accessors --------------------------------------------------

    /// Read-only peek at a room's state.
    pub fn state_for(&self, room: &str) -> Option<&ZoneState> {
        self.states.get(room)
    }

    /// Set the physical-on flag for a room directly.
    pub fn set_physical_state(&mut self, room: &str, on: bool) {
        let state = self.states.entry(room.to_string()).or_default();
        state.physically_on = on;
    }

    /// Turn off all motion-controlled rooms that are physically on at
    /// startup. Non-motion rooms are left user-owned (logged only).
    ///
    /// Deliberately does NOT set `last_off_at` so that motion sensors
    /// can immediately re-trigger the lights if someone is in the room.
    pub fn startup_turn_off_motion_zones(&mut self, _ts: Instant) -> Vec<Action> {
        let mut out = Vec::new();
        for room in self.topology.rooms() {
            let state = self.states.entry(room.name.clone()).or_default();
            if !state.physically_on {
                continue;
            }
            if room.has_motion_sensor() {
                tracing::info!(
                    room = %room.name,
                    group = %room.group_name,
                    transition = room.off_transition_seconds,
                    "startup: turning off motion-controlled zone (no cooldown)"
                );
                state.physically_on = false;
                state.motion_owned = false;
                state.cycle_idx = 0;
                // Deliberately skip last_off_at — no cooldown after startup turn-off.
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

    /// Read-only access to every room's state.
    pub fn all_room_states(&self) -> &BTreeMap<RoomName, ZoneState> {
        &self.states
    }

    /// Read-only access to every plug's runtime state.
    pub fn all_plug_states(&self) -> &BTreeMap<String, PlugRuntimeState> {
        &self.plug_states
    }

    /// True if a kill-switch holdoff is currently running for the given
    /// action rule.
    pub fn is_kill_switch_idle(&self, rule_name: &str) -> bool {
        self.kill_switch.is_idle(rule_name)
    }

    /// Earliest kill-switch idle start across all `PowerBelow` rules
    /// targeting `device`.
    pub fn earliest_kill_switch_idle(&self, device: &str) -> Option<Instant> {
        self.kill_switch.earliest_idle(device)
    }

    /// Reference to the immutable topology.
    pub fn topology(&self) -> &Arc<Topology> {
        &self.topology
    }

    /// Reference to the clock.
    pub fn clock(&self) -> &Arc<dyn Clock> {
        &self.clock
    }

    /// Read-only access to the heating sub-controller's runtime state.
    pub fn heating_state(&self) -> Option<&crate::domain::heating_state::HeatingRuntimeState> {
        self.heating.as_ref().map(|hc| hc.state())
    }

    /// Reference to the geographic location (if configured).
    pub fn location(&self) -> Option<&crate::sun::Location> {
        self.location.as_ref()
    }

    /// Compute (and cache) sun times for today. Returns `None` if no
    /// location is configured. Returns a copy so callers don't hold a
    /// borrow on `self`.
    pub fn sun_times(&mut self) -> Option<crate::sun::SunTimes> {
        let loc = self.location.as_ref()?;
        let info = self.clock.local_date_info();
        // Truncate offset to seconds for cache key — catches DST transitions
        // within the same date (e.g. CET→CEST changes UTC offset by 3600s).
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

    /// Helper: get the current scene IDs for a room, taking sun times
    /// into account.
    fn scenes_for_room(&mut self, room_name: &str) -> Vec<u8> {
        let sun = self.sun_times();
        let hour = self.clock.local_hour();
        let minute = self.clock.local_minute();
        let Some(room) = self.topology.room_by_name(room_name) else {
            return Vec::new();
        };
        active_slot_scene_ids(&room.scenes, hour, minute, sun.as_ref())
    }

    // ----- group state handler (small, stays in mod.rs) ---------------------

    fn handle_group_state(&mut self, group_name: &str, on: bool, ts: Instant) -> Vec<Action> {
        let Some(room) = self.topology.room_by_group_name(group_name) else {
            return Vec::new();
        };
        let room_name = room.name.clone();
        let state = self.states.entry(room_name.clone()).or_default();
        let was_on = state.physically_on;
        state.physically_on = on;

        if was_on == on {
            tracing::debug!(
                group = group_name,
                room = %room_name,
                state = on,
                "group state echo → no transition"
            );
            return Vec::new();
        }

        if on {
            tracing::info!(
                group = group_name,
                room = %room_name,
                from = was_on,
                to = on,
                "group state echo → off→on transition (leaving user-owned)"
            );
        } else {
            state.motion_owned = false;
            state.cycle_idx = 0;
            state.last_off_at = Some(ts);
            tracing::info!(
                group = group_name,
                room = %room_name,
                from = was_on,
                to = on,
                "group state echo → on→off transition (motion ownership cleared)"
            );
        }

        // Propagate only the physical on/off flag to descendants so
        // child rooms track the parent's physical state.  Use the
        // *soft* variant that preserves cycle state (last_press_at,
        // cycle_idx) — a group echo is NOT an explicit button press,
        // so it must not destroy a child's in-progress scene cycle.
        self.soft_propagate_to_descendants(&room_name, on, ts);

        Vec::new()
    }

    // ----- web command handlers ---------------------------------------------
    //
    // These mirror the wall-switch / tap paths but are triggered by the
    // web UI. They go through the same state machine updates (write_after_on,
    // publish_off, propagate_to_descendants) so the controller stays
    // consistent between MQTT echoes.

    /// Web UI: recall a specific scene in a room.
    pub fn web_recall_scene(&mut self, room_name: &str, scene_id: u8, ts: Instant) -> Vec<Action> {
        let scenes_for_now = self.scenes_for_room(room_name);
        let Some(room) = self.topology.room_by_name(room_name) else {
            return Vec::new();
        };
        let group_name = room.group_name.clone();

        // Find the cycle index for this scene_id; default to 0.
        let cycle_idx = scenes_for_now
            .iter()
            .position(|&id| id == scene_id)
            .unwrap_or(0);

        tracing::info!(
            room = room_name,
            group = %group_name,
            scene = scene_id,
            cycle_idx,
            "web: recall scene → scene_recall (controller path)"
        );

        let action = Action::new(group_name, Payload::scene_recall(scene_id));
        self.write_after_on(room_name, ts, cycle_idx);
        self.propagate_to_descendants(room_name, true, ts);
        vec![action]
    }

    /// Web UI: turn a room off.
    pub fn web_set_room_off(&mut self, room_name: &str, ts: Instant) -> Vec<Action> {
        let Some(room) = self.topology.room_by_name(room_name) else {
            return Vec::new();
        };
        let group_name = room.group_name.clone();
        let off_transition = room.off_transition_seconds;

        tracing::info!(
            room = room_name,
            group = %group_name,
            transition = off_transition,
            "web: set room off (controller path)"
        );

        let mut out = Vec::new();
        self.publish_off(room_name, &group_name, off_transition, ts, &mut out);
        out
    }

    /// Web UI: toggle a smart plug.
    pub fn web_toggle_plug(&mut self, device: &str, ts: Instant) -> Vec<Action> {
        if !self.topology.is_plug(device) {
            tracing::warn!(device, "web: toggle plug rejected — unknown device");
            return Vec::new();
        }
        let is_on = self
            .plug_state_for(device)
            .map_or(false, |s| s.on);
        let action = if is_on {
            Action::for_device(device.to_string(), Payload::device_off())
        } else {
            Action::for_device(device.to_string(), Payload::device_on())
        };

        // Optimistically update plug state so rapid toggles don't
        // derive the next command from stale state. Matches the
        // Toggle/TurnOn/TurnOff patterns in actions.rs: kill-switch
        // arming is NOT done here — it happens on the confirmed ON
        // echo in handle_plug_state (on == Some(true) && !was_on).
        let plug = self.plug_states.entry(device.to_string()).or_default();
        if is_on {
            plug.on = false;
            plug.seen_explicit_off = true;
            plug.last_power = None;
            self.kill_switch.on_plug_off(device);
        } else {
            if plug.seen_explicit_off {
                plug.last_power = None;
            }
            plug.on = true;
            plug.seen_explicit_off = false;
        }

        tracing::info!(device, target_state = !is_on, "web: toggle plug (controller path)");
        vec![action]
    }

    // ----- tick handler (dispatches to actions + kill_switch) ---------------

    fn handle_tick(&mut self, ts: Instant) -> Vec<Action> {
        let mut out = self.evaluate_at_triggers(ts);

        // Kill-switch deadline evaluation.
        let plug_states = &self.plug_states;
        let fired = self.kill_switch.tick(ts, &|device| {
            plug_states.get(device).is_some_and(|p| p.on)
        });
        out.extend(self.apply_kill_switch_fired(&fired));

        // Heating tick.
        if let Some(ref mut hc) = self.heating {
            out.extend(hc.handle_tick());
        }

        out
    }

    // ----- shared helpers ---------------------------------------------------

    fn write_after_on(&mut self, room_name: &str, ts: Instant, cycle_idx_after: usize) {
        let state = self.states.entry(room_name.to_string()).or_default();
        state.physically_on = true;
        state.cycle_idx = cycle_idx_after;
        state.last_press_at = Some(ts);
        // Manual press supersedes any motion ownership.
        state.motion_owned = false;
    }

    fn write_after_off(&mut self, room_name: &str, ts: Instant) {
        let state = self.states.entry(room_name.to_string()).or_default();
        state.physically_on = false;
        state.cycle_idx = 0;
        state.last_press_at = Some(ts);
        state.last_off_at = Some(ts);
        state.motion_owned = false;
    }

    /// Soft propagation: update only `physically_on` (and `last_off_at`
    /// on off transitions) for descendants.  Does NOT reset
    /// `last_press_at`, `cycle_idx`, or `motion_owned`.
    ///
    /// Used by `handle_group_state` where the echo is a side-effect of
    /// z2m aggregating member states, not an explicit user action.  If
    /// we cleared cycle state here, a child room's tap-press cycle
    /// window would be destroyed every time z2m re-publishes the
    /// parent group's state after the child turned on.
    fn soft_propagate_to_descendants(&mut self, ancestor: &str, on: bool, ts: Instant) {
        let descendants: Vec<RoomName> = self.topology.descendants_of(ancestor).to_vec();
        if descendants.is_empty() {
            return;
        }
        tracing::debug!(
            ancestor,
            descendants = ?descendants,
            physically_on = on,
            "group echo: soft-propagating physical state to descendants \
             (preserving cycle state)"
        );
        for desc in descendants {
            let state = self.states.entry(desc).or_default();
            state.physically_on = on;
            if !on {
                state.last_off_at = Some(ts);
            }
        }
    }

    /// Optimistically propagate a parent's new physical state to every
    /// transitive descendant.
    fn propagate_to_descendants(&mut self, ancestor: &str, on: bool, ts: Instant) {
        let descendants: Vec<RoomName> = self.topology.descendants_of(ancestor).to_vec();
        if descendants.is_empty() {
            return;
        }
        tracing::info!(
            ancestor,
            descendants = ?descendants,
            physically_on = on,
            "propagating physical state to descendants (next press takes \
             toggle-off branch instead of fresh-on)"
        );
        for desc in descendants {
            let state = self.states.entry(desc).or_default();
            state.physically_on = on;
            state.last_press_at = None;
            state.cycle_idx = 0;
            state.motion_owned = false;
            if !on {
                state.last_off_at = Some(ts);
            }
        }
    }
}

/// Pull out the `scene_ids` of the slot covering `(hour, minute)`.
fn active_slot_scene_ids(
    schedule: &crate::config::SceneSchedule,
    hour: u8,
    minute: u8,
    sun: Option<&crate::sun::SunTimes>,
) -> Vec<u8> {
    let Some((_name, slot)) = schedule.slot_for_time(hour, minute, sun) else {
        return Vec::new();
    };
    slot.scene_ids.clone()
}

#[cfg(test)]
mod tests {
    //! Unit tests for the controller state machine. These run directly
    //! against the controller — no MQTT, no async, sub-millisecond per
    //! test. Each test sets up a small topology, feeds events with a
    //! fake clock, and asserts on the returned actions plus the
    //! resulting zone state.

    use super::*;
    use crate::config::scenes::{Scene, SceneSchedule, Slot};
    use crate::config::{
        CommonFields, Config, DeviceBinding, DeviceCatalogEntry, Defaults, Room,
    };
    use crate::domain::action::Payload;
    use crate::domain::event::SwitchAction;
    use crate::time::FakeClock;
    use pretty_assertions::assert_eq;
    use std::time::Duration;

    // ---- fixtures -------------------------------------------------------

    fn day_scenes(ids: Vec<u8>) -> SceneSchedule {
        SceneSchedule {
            scenes: ids
                .iter()
                .map(|&id| Scene {
                    id,
                    name: format!("scene-{id}"),
                    state: "ON".into(),
                    brightness: None,
                    color_temp: None,
                    transition: 0.0,
                })
                .collect(),
            slots: BTreeMap::from([(
                "day".into(),
                Slot {
                    from: fixed_time(0, 0),
                    to: fixed_time(24, 0),
                    scene_ids: ids,
                },
            )]),
        }
    }

    fn fixed_time(h: u8, m: u8) -> crate::config::TimeExpr {
        crate::config::TimeExpr::Fixed { minute_of_day: h as u16 * 60 + m as u16 }
    }

    fn day_night_scenes() -> SceneSchedule {
        let scenes = vec![
            Scene { id: 1, name: "bright".into(), state: "ON".into(), brightness: None, color_temp: None, transition: 0.0 },
            Scene { id: 2, name: "relaxed".into(), state: "ON".into(), brightness: None, color_temp: None, transition: 0.0 },
            Scene { id: 3, name: "dim".into(), state: "ON".into(), brightness: None, color_temp: None, transition: 0.0 },
        ];
        SceneSchedule {
            scenes,
            slots: BTreeMap::from([
                ("day".into(), Slot { from: fixed_time(6, 0), to: fixed_time(23, 0), scene_ids: vec![1, 2, 3] }),
                ("night".into(), Slot { from: fixed_time(23, 0), to: fixed_time(6, 0), scene_ids: vec![3, 2, 1] }),
            ]),
        }
    }

    fn light(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Light(CommonFields { ieee_address: ieee.into(), description: None, options: BTreeMap::new() })
    }
    fn switch_dev(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Switch(CommonFields { ieee_address: ieee.into(), description: None, options: BTreeMap::new() })
    }
    fn tap_dev(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Tap(CommonFields { ieee_address: ieee.into(), description: None, options: BTreeMap::new() })
    }
    fn motion(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::MotionSensor {
            common: CommonFields { ieee_address: ieee.into(), description: None, options: BTreeMap::new() },
            occupancy_timeout_seconds: 60,
            max_illuminance: None,
        }
    }

    fn binding(device: &str, button: Option<u8>) -> DeviceBinding {
        DeviceBinding { device: device.into(), button, cycle_on_double_tap: false }
    }

    fn binding_double_tap(device: &str, button: u8) -> DeviceBinding {
        DeviceBinding { device: device.into(), button: Some(button), cycle_on_double_tap: true }
    }

    fn kitchen_controller(clock: Arc<FakeClock>) -> Controller {
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([
                ("hue-l-cooker".into(), light("0xa")),
                ("hue-l-dining".into(), light("0xb")),
                ("hue-l-empty".into(), light("0xc")),
                ("hue-ts-foo".into(), tap_dev("0x1")),
            ]),
            rooms: vec![
                Room {
                    name: "kitchen-cooker".into(), group_name: "hue-lz-kitchen-cooker".into(), id: 1,
                    members: vec!["hue-l-cooker/11".into()], parent: Some("kitchen-all".into()),
                    devices: vec![binding("hue-ts-foo", Some(2))],
                    scenes: day_scenes(vec![1, 2, 3]), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 0,
                },
                Room {
                    name: "kitchen-dining".into(), group_name: "hue-lz-kitchen-dining".into(), id: 2,
                    members: vec!["hue-l-dining/11".into()], parent: Some("kitchen-all".into()),
                    devices: vec![binding("hue-ts-foo", Some(3))],
                    scenes: day_scenes(vec![1, 2, 3]), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 0,
                },
                Room {
                    name: "kitchen-all".into(), group_name: "hue-lz-kitchen-all".into(), id: 3,
                    members: vec!["hue-l-cooker/11".into(), "hue-l-dining/11".into(), "hue-l-empty/11".into()],
                    parent: None, devices: vec![binding("hue-ts-foo", Some(1))],
                    scenes: day_scenes(vec![1, 2, 3]), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 0,
                },
            ],
            actions: vec![],
            defaults: Defaults::default(),
            heating: None,
            location: None,
        };
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        Controller::new(topo, clock, cfg.defaults, None)
    }

    fn study_with_motion_controller(clock: Arc<FakeClock>) -> Controller {
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([
                ("hue-l-a".into(), light("0xa")),
                ("hue-s-study".into(), switch_dev("0x1")),
                ("hue-ms-study".into(), motion("0x2")),
            ]),
            rooms: vec![Room {
                name: "study".into(), group_name: "hue-lz-study".into(), id: 1,
                members: vec!["hue-l-a/11".into()], parent: None,
                devices: vec![binding("hue-s-study", None), binding("hue-ms-study", None)],
                scenes: day_night_scenes(), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 30,
            }],
            actions: vec![],
            defaults: Defaults::default(),
            heating: None,
            location: None,
        };
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        Controller::new(topo, clock, cfg.defaults, None)
    }

    // ---- cycle button: fresh on / cycle / expire ------------------------

    #[test]
    fn tap_press_on_off_zone_publishes_first_scene() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        let actions = c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 2, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-cooker", Payload::scene_recall(1))]);
        let s = c.state_for("kitchen-cooker").unwrap();
        assert!(s.physically_on);
        assert_eq!(s.cycle_idx, 0);
        assert!(s.last_press_at.is_some());
    }

    #[test]
    fn tap_press_within_window_cycles_scene() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 2, ts: clk.now() });
        clk.advance(Duration::from_millis(200));
        let actions = c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 2, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-cooker", Payload::scene_recall(2))]);
        assert_eq!(c.state_for("kitchen-cooker").unwrap().cycle_idx, 1);
    }

    #[test]
    fn tap_press_outside_window_expires_to_off() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 2, ts: clk.now() });
        clk.advance(Duration::from_millis(1500));
        let actions = c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 2, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-cooker", Payload::state_off(0.8))]);
        assert!(!c.state_for("kitchen-cooker").unwrap().physically_on);
    }

    #[test]
    fn tap_cycle_wraps_at_n() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        for _ in 0..3 {
            c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 2, ts: clk.now() });
            clk.advance(Duration::from_millis(100));
        }
        let actions = c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 2, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-cooker", Payload::scene_recall(1))]);
    }

    // ---- parent/child propagation ----------------------------------------

    #[test]
    fn parent_on_then_child_press_toggles_child_off() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        let p = c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 1, ts: clk.now() });
        assert_eq!(p, vec![Action::new("hue-lz-kitchen-all", Payload::scene_recall(1))]);
        assert!(c.state_for("kitchen-cooker").unwrap().physically_on);
        assert!(c.state_for("kitchen-cooker").unwrap().last_press_at.is_none());
        clk.advance(Duration::from_millis(150));
        let actions = c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 2, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-cooker", Payload::state_off(0.8))]);
        assert!(!c.state_for("kitchen-cooker").unwrap().physically_on);
    }

    #[test]
    fn parent_on_then_delayed_child_press_still_toggles_off() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 1, ts: clk.now() });
        clk.advance(Duration::from_millis(2500));
        let actions = c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 2, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-cooker", Payload::state_off(0.8))]);
    }

    #[test]
    fn parent_on_then_child_off_then_child_on_fresh() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 1, ts: clk.now() });
        clk.advance(Duration::from_millis(100));
        c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 2, ts: clk.now() });
        clk.advance(Duration::from_millis(100));
        let actions = c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 2, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-cooker", Payload::scene_recall(1))]);
    }

    #[test]
    fn child_press_does_not_alter_parent_state() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 2, ts: clk.now() });
        clk.advance(Duration::from_millis(100));
        let actions = c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 1, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-all", Payload::scene_recall(1))]);
    }

    #[test]
    fn parent_cycle_keeps_descendants_marked_on() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 1, ts: clk.now() });
        clk.advance(Duration::from_millis(200));
        c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 1, ts: clk.now() });
        clk.advance(Duration::from_millis(200));
        let actions = c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 2, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-cooker", Payload::state_off(0.8))]);
    }

    #[test]
    fn sibling_press_independent_of_other_sibling() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 2, ts: clk.now() });
        clk.advance(Duration::from_millis(100));
        let actions = c.handle_event(Event::TapAction { action: None, device: "hue-ts-foo".into(), button: 3, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-dining", Payload::scene_recall(1))]);
    }

    // ---- wall switch on button -------------------------------------------

    #[test]
    fn wall_switch_on_press_from_off_publishes_first_scene() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        let actions = c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::OnPressRelease, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-study", Payload::scene_recall(1))]);
        let s = c.state_for("study").unwrap();
        assert!(s.physically_on);
        assert_eq!(s.cycle_idx, 0);
    }

    #[test]
    fn wall_switch_on_press_within_window_cycles_scene() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::OnPressRelease, ts: clk.now() });
        clk.advance(Duration::from_millis(200));
        let actions = c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::OnPressRelease, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-study", Payload::scene_recall(2))]);
        assert_eq!(c.state_for("study").unwrap().cycle_idx, 1);
    }

    #[test]
    fn wall_switch_on_press_advances_cycle_with_no_time_component() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        let a1 = c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::OnPressRelease, ts: clk.now() });
        assert_eq!(a1, vec![Action::new("hue-lz-study", Payload::scene_recall(1))]);
        clk.advance(Duration::from_secs(60));
        let a2 = c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::OnPressRelease, ts: clk.now() });
        assert_eq!(a2, vec![Action::new("hue-lz-study", Payload::scene_recall(2))],
            "wall switch press should always advance the cycle, regardless of how long ago the previous press was");
        clk.advance(Duration::from_secs(300));
        let a3 = c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::OnPressRelease, ts: clk.now() });
        assert_eq!(a3, vec![Action::new("hue-lz-study", Payload::scene_recall(3))]);
        clk.advance(Duration::from_secs(10));
        let a4 = c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::OnPressRelease, ts: clk.now() });
        assert_eq!(a4, vec![Action::new("hue-lz-study", Payload::scene_recall(1))]);
    }

    #[test]
    fn wall_switch_off_press_resets_cycle_index() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        for _ in 0..3 {
            c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::OnPressRelease, ts: clk.now() });
            clk.advance(Duration::from_millis(100));
        }
        assert_eq!(c.state_for("study").unwrap().cycle_idx, 2);
        c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::OffPressRelease, ts: clk.now() });
        assert!(!c.state_for("study").unwrap().physically_on);
        let actions = c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::OnPressRelease, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-study", Payload::scene_recall(1))]);
    }

    #[test]
    fn wall_switch_full_cycle_walks_all_scenes_then_wraps() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        let mut emitted: Vec<u8> = Vec::new();
        for _ in 0..4 {
            let actions = c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::OnPressRelease, ts: clk.now() });
            assert_eq!(actions.len(), 1);
            if let Payload::SceneRecall { scene_recall } = actions[0].payload { emitted.push(scene_recall); }
            else { panic!("expected SceneRecall, got {:?}", actions[0].payload); }
            clk.advance(Duration::from_millis(200));
        }
        assert_eq!(emitted, vec![1, 2, 3, 1]);
    }

    // ---- wall switch off + brightness ------------------------------------

    #[test]
    fn wall_switch_off_press_immediately_off() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        c.set_physical_state("study", true);
        let actions = c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::OffPressRelease, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-study", Payload::state_off(0.8))]);
    }

    #[test]
    fn wall_switch_brightness_up_press_release() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        let actions = c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::UpPressRelease, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-study", Payload::brightness_step(25, 0.2))]);
    }

    #[test]
    fn wall_switch_brightness_down_press_release() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        let actions = c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::DownPressRelease, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-study", Payload::brightness_step(-25, 0.2))]);
    }

    #[test]
    fn wall_switch_hold_and_release_brightness_move() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        let hold = c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::UpHold, ts: clk.now() });
        assert_eq!(hold, vec![Action::new("hue-lz-study", Payload::brightness_move(40))]);
        let release = c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::UpHoldRelease, ts: clk.now() });
        assert_eq!(release, vec![Action::new("hue-lz-study", Payload::brightness_move(0))]);
    }

    // ---- motion sensor --------------------------------------------------

    #[test]
    fn motion_on_in_dark_room_publishes_first_scene() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        let actions = c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: true, illuminance: None, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-study", Payload::scene_recall(1))]);
        let s = c.state_for("study").unwrap();
        assert!(s.physically_on);
        assert!(s.motion_owned);
    }

    #[test]
    fn motion_on_skipped_when_lights_already_on() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        c.set_physical_state("study", true);
        let actions = c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: true, illuminance: None, ts: clk.now() });
        assert!(actions.is_empty());
        assert!(c.state_for("study").unwrap().motion_active_by_sensor.get("hue-ms-study").copied().unwrap_or(false));
    }

    #[test]
    fn motion_off_only_after_owning_motion_on() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: true, illuminance: None, ts: clk.now() });
        clk.advance(Duration::from_secs(60));
        let actions = c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: false, illuminance: None, ts: clk.now() });
        assert_eq!(actions, vec![Action::new("hue-lz-study", Payload::state_off(0.8))]);
    }

    #[test]
    fn motion_off_skipped_when_user_owns_lights() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::OnPressRelease, ts: clk.now() });
        c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: true, illuminance: None, ts: clk.now() });
        clk.advance(Duration::from_secs(60));
        let actions = c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: false, illuminance: None, ts: clk.now() });
        assert!(actions.is_empty());
    }

    #[test]
    fn motion_cooldown_blocks_motion_on_after_recent_off() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: true, illuminance: None, ts: clk.now() });
        clk.advance(Duration::from_secs(60));
        c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: false, illuminance: None, ts: clk.now() });
        clk.advance(Duration::from_secs(5));
        let blocked = c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: true, illuminance: None, ts: clk.now() });
        assert!(blocked.is_empty());
        clk.advance(Duration::from_secs(30));
        let allowed = c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: true, illuminance: None, ts: clk.now() });
        assert_eq!(allowed, vec![Action::new("hue-lz-study", Payload::scene_recall(1))]);
    }

    #[test]
    fn motion_luminance_gate() {
        let clk = Arc::new(FakeClock::new(12));
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([
                ("hue-l-a".into(), light("0xa")),
                ("hue-ms-study".into(), DeviceCatalogEntry::MotionSensor {
                    common: CommonFields { ieee_address: "0x2".into(), description: None, options: BTreeMap::new() },
                    occupancy_timeout_seconds: 60, max_illuminance: Some(25),
                }),
            ]),
            rooms: vec![Room {
                name: "study".into(), group_name: "hue-lz-study".into(), id: 1,
                members: vec!["hue-l-a/11".into()], parent: None,
                devices: vec![binding("hue-ms-study", None)],
                scenes: day_scenes(vec![1]), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 0,
            }],
            actions: vec![], defaults: Defaults::default(), heating: None, location: None,
        };
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        let mut c = Controller::new(topo, clk.clone(), cfg.defaults, None);
        let bright = c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: true, illuminance: Some(50), ts: clk.now() });
        assert!(bright.is_empty());
        let dim = c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: true, illuminance: Some(10), ts: clk.now() });
        assert_eq!(dim, vec![Action::new("hue-lz-study", Payload::scene_recall(1))]);
    }

    #[test]
    fn motion_off_fires_regardless_of_high_illuminance() {
        let clk = Arc::new(FakeClock::new(12));
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([
                ("hue-l-a".into(), light("0xa")),
                ("hue-ms-study".into(), DeviceCatalogEntry::MotionSensor {
                    common: CommonFields { ieee_address: "0x2".into(), description: None, options: BTreeMap::new() },
                    occupancy_timeout_seconds: 60, max_illuminance: Some(25),
                }),
            ]),
            rooms: vec![Room {
                name: "study".into(), group_name: "hue-lz-study".into(), id: 1,
                members: vec!["hue-l-a/11".into()], parent: None,
                devices: vec![binding("hue-ms-study", None)],
                scenes: day_scenes(vec![1]), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 0,
            }],
            actions: vec![], defaults: Defaults::default(), heating: None, location: None,
        };
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        let mut c = Controller::new(topo, clk.clone(), cfg.defaults, None);
        let on = c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: true, illuminance: Some(10), ts: clk.now() });
        assert_eq!(on, vec![Action::new("hue-lz-study", Payload::scene_recall(1))]);
        assert!(c.state_for("study").unwrap().motion_owned);
        clk.advance(Duration::from_secs(30));
        let bright_occupied = c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: true, illuminance: Some(100), ts: clk.now() });
        assert!(bright_occupied.is_empty());
        clk.advance(Duration::from_secs(10));
        let off = c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: false, illuminance: Some(100), ts: clk.now() });
        assert_eq!(off, vec![Action::new("hue-lz-study", Payload::state_off(0.8))]);
        assert!(!c.state_for("study").unwrap().motion_owned);
        assert!(!c.state_for("study").unwrap().physically_on);
    }

    // ---- multi-sensor coordination --------------------------------------

    #[test]
    fn multi_sensor_motion_off_waits_for_all_inactive() {
        let clk = Arc::new(FakeClock::new(12));
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([
                ("hue-l-a".into(), light("0xa")),
                ("hue-ms-a".into(), motion("0x1")),
                ("hue-ms-b".into(), motion("0x2")),
            ]),
            rooms: vec![Room {
                name: "hall".into(), group_name: "hue-lz-hall".into(), id: 1,
                members: vec!["hue-l-a/11".into()], parent: None,
                devices: vec![binding("hue-ms-a", None), binding("hue-ms-b", None)],
                scenes: day_scenes(vec![1]), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 0,
            }],
            actions: vec![], defaults: Defaults::default(), heating: None, location: None,
        };
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        let mut c = Controller::new(topo, clk.clone(), cfg.defaults, None);
        c.handle_event(Event::Occupancy { sensor: "hue-ms-a".into(), occupied: true, illuminance: None, ts: clk.now() });
        c.handle_event(Event::Occupancy { sensor: "hue-ms-b".into(), occupied: true, illuminance: None, ts: clk.now() });
        let no_off = c.handle_event(Event::Occupancy { sensor: "hue-ms-a".into(), occupied: false, illuminance: None, ts: clk.now() });
        assert!(no_off.is_empty());
        let off = c.handle_event(Event::Occupancy { sensor: "hue-ms-b".into(), occupied: false, illuminance: None, ts: clk.now() });
        assert_eq!(off, vec![Action::new("hue-lz-hall", Payload::state_off(0.8))]);
    }

    // ---- cycle_on_double_tap ------------------------------------------------

    fn double_tap_controller(clock: Arc<FakeClock>) -> Controller {
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([
                ("hue-l-a".into(), light("0xa")),
                ("sonoff-ts-foo".into(), tap_dev("0x1")),
            ]),
            rooms: vec![Room {
                name: "bedroom".into(), group_name: "hue-lz-bedroom".into(), id: 1,
                members: vec!["hue-l-a/11".into()], parent: None,
                devices: vec![binding_double_tap("sonoff-ts-foo", 1)],
                scenes: day_night_scenes(), off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
            }],
            actions: vec![], defaults: Defaults::default(), heating: None, location: None,
        };
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        Controller::new(topo, clock, cfg.defaults, None)
    }

    #[test]
    fn double_tap_single_tap_turns_on_first_scene() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = double_tap_controller(clk.clone());
        let actions = c.handle_event(Event::TapAction {
            device: "sonoff-ts-foo".into(), button: 1, action: None, ts: clk.now(),
        });
        assert_eq!(actions, vec![Action::new("hue-lz-bedroom", Payload::scene_recall(1))]);
        assert!(c.state_for("bedroom").unwrap().physically_on);
    }

    #[test]
    fn double_tap_single_tap_turns_off() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = double_tap_controller(clk.clone());
        // Turn on first.
        c.handle_event(Event::TapAction {
            device: "sonoff-ts-foo".into(), button: 1, action: None, ts: clk.now(),
        });
        clk.advance(Duration::from_secs(5));
        // Single tap again → off (no cycle window involved).
        let actions = c.handle_event(Event::TapAction {
            device: "sonoff-ts-foo".into(), button: 1, action: None, ts: clk.now(),
        });
        assert_eq!(actions, vec![Action::new("hue-lz-bedroom", Payload::state_off(0.8))]);
        assert!(!c.state_for("bedroom").unwrap().physically_on);
    }

    #[test]
    fn double_tap_cycles_scenes() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = double_tap_controller(clk.clone());
        // Turn on via single tap.
        c.handle_event(Event::TapAction {
            device: "sonoff-ts-foo".into(), button: 1, action: None, ts: clk.now(),
        });
        // Double tap → advance to scene 2.
        let actions = c.handle_event(Event::TapAction {
            device: "sonoff-ts-foo".into(), button: 1,
            action: Some("double".into()), ts: clk.now(),
        });
        assert_eq!(actions, vec![Action::new("hue-lz-bedroom", Payload::scene_recall(2))]);
        assert_eq!(c.state_for("bedroom").unwrap().cycle_idx, 1);
    }

    #[test]
    fn double_tap_cycle_wraps() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = double_tap_controller(clk.clone());
        // Turn on via single tap (cycle_idx = 0, scene 1).
        c.handle_event(Event::TapAction {
            device: "sonoff-ts-foo".into(), button: 1, action: None, ts: clk.now(),
        });
        // Double tap → scene 2 (cycle_idx = 1).
        c.handle_event(Event::TapAction {
            device: "sonoff-ts-foo".into(), button: 1,
            action: Some("double".into()), ts: clk.now(),
        });
        // Double tap → scene 3 (cycle_idx = 2).
        c.handle_event(Event::TapAction {
            device: "sonoff-ts-foo".into(), button: 1,
            action: Some("double".into()), ts: clk.now(),
        });
        // Double tap → wraps to scene 1 (cycle_idx = 0).
        let actions = c.handle_event(Event::TapAction {
            device: "sonoff-ts-foo".into(), button: 1,
            action: Some("double".into()), ts: clk.now(),
        });
        assert_eq!(actions, vec![Action::new("hue-lz-bedroom", Payload::scene_recall(1))]);
        assert_eq!(c.state_for("bedroom").unwrap().cycle_idx, 0);
    }

    #[test]
    fn double_tap_on_off_room_turns_on() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = double_tap_controller(clk.clone());
        // Double tap when off → turns on with first scene.
        let actions = c.handle_event(Event::TapAction {
            device: "sonoff-ts-foo".into(), button: 1,
            action: Some("double".into()), ts: clk.now(),
        });
        assert_eq!(actions, vec![Action::new("hue-lz-bedroom", Payload::scene_recall(1))]);
        assert!(c.state_for("bedroom").unwrap().physically_on);
    }

    // ---- startup turn-off for motion zones --------------------------------

    #[test]
    fn startup_turns_off_lit_motion_rooms() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        c.set_physical_state("study", true);
        let actions = c.startup_turn_off_motion_zones(clk.now());
        assert_eq!(actions, vec![Action::new("hue-lz-study", Payload::state_off(0.8))]);
        let s = c.state_for("study").unwrap();
        assert!(!s.physically_on);
        assert!(!s.motion_owned);
    }

    #[test]
    fn startup_skips_unlit_motion_rooms() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        c.set_physical_state("study", false);
        let actions = c.startup_turn_off_motion_zones(clk.now());
        assert!(actions.is_empty());
    }

    #[test]
    fn startup_no_cooldown_after_turn_off() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        c.set_physical_state("study", true);
        let _ = c.startup_turn_off_motion_zones(clk.now());
        assert!(c.state_for("study").unwrap().last_off_at.is_none(),
            "startup turn-off must not set cooldown");
        // Motion can immediately re-trigger.
        let on = c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(), occupied: true,
            illuminance: Some(10), ts: clk.now(),
        });
        assert_eq!(on, vec![Action::new("hue-lz-study", Payload::scene_recall(1))]);
    }

    #[test]
    fn startup_motion_off_suppressed_room_already_off() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        c.set_physical_state("study", true);
        let _ = c.startup_turn_off_motion_zones(clk.now());
        let actions = c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(), occupied: false,
            illuminance: None, ts: clk.now(),
        });
        assert!(actions.is_empty(), "motion-off suppressed: room already off after startup");
    }

    #[test]
    fn startup_leaves_non_motion_rooms_on() {
        let clk = Arc::new(FakeClock::new(12));
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([
                ("hue-l-a".into(), light("0xa")),
                ("hue-s-foo".into(), switch_dev("0x1")),
            ]),
            rooms: vec![Room {
                name: "office".into(), group_name: "hue-lz-office".into(), id: 1,
                members: vec!["hue-l-a/11".into()], parent: None,
                devices: vec![binding("hue-s-foo", None)],
                scenes: day_scenes(vec![1]), off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
            }],
            actions: vec![], defaults: Defaults::default(), heating: None, location: None,
        };
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        let mut c = Controller::new(topo, clk.clone(), cfg.defaults, None);
        c.set_physical_state("office", true);
        let actions = c.startup_turn_off_motion_zones(clk.now());
        assert!(actions.is_empty(), "non-motion rooms must not be turned off at startup");
        assert!(c.state_for("office").unwrap().physically_on);
    }

    // ---- group state reconciliation -------------------------------------

    #[test]
    fn external_group_off_resets_zone_state() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: true, illuminance: None, ts: clk.now() });
        assert!(c.state_for("study").unwrap().motion_owned);
        c.handle_event(Event::GroupState { group: "hue-lz-study".into(), on: false, ts: clk.now() });
        let s = c.state_for("study").unwrap();
        assert!(!s.physically_on);
        assert!(!s.motion_owned);
    }

    #[test]
    fn group_state_same_state_echo_is_a_noop() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: true, illuminance: None, ts: clk.now() });
        assert!(c.state_for("study").unwrap().motion_owned);
        c.handle_event(Event::GroupState { group: "hue-lz-study".into(), on: true, ts: clk.now() });
        assert!(c.state_for("study").unwrap().motion_owned);
    }

    #[test]
    fn external_off_to_on_transition_stays_user_owned() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        assert!(!c.state_for("study").map(|s| s.physically_on).unwrap_or(false));
        c.handle_event(Event::GroupState { group: "hue-lz-study".into(), on: true, ts: clk.now() });
        let s = c.state_for("study").unwrap();
        assert!(s.physically_on);
        assert!(!s.motion_owned, "external off→on transition must stay user-owned");
    }

    #[test]
    fn external_on_to_off_transition_clears_motion_ownership() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: true, illuminance: None, ts: clk.now() });
        c.handle_event(Event::GroupState { group: "hue-lz-study".into(), on: false, ts: clk.now() });
        let s = c.state_for("study").unwrap();
        assert!(!s.physically_on);
        assert!(!s.motion_owned);
        assert_eq!(s.cycle_idx, 0);
    }

    #[test]
    fn motion_off_suppressed_after_external_on_without_prior_occupancy() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        c.handle_event(Event::GroupState { group: "hue-lz-study".into(), on: true, ts: clk.now() });
        let actions = c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: false, illuminance: None, ts: clk.now() });
        assert!(actions.is_empty(), "motion-off must be suppressed after external on (user-owned)");
    }

    #[test]
    fn external_on_then_full_motion_cycle_auto_offs() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        c.handle_event(Event::GroupState { group: "hue-lz-study".into(), on: true, ts: clk.now() });
        c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: true, illuminance: None, ts: clk.now() });
        assert!(!c.state_for("study").unwrap().motion_owned);
        let actions = c.handle_event(Event::Occupancy { sensor: "hue-ms-study".into(), occupied: false, illuminance: None, ts: clk.now() });
        assert!(actions.is_empty(), "room is user-owned; motion-off must not fire");
    }

    // ---- group echo must not destroy child cycle window ------------------

    #[test]
    fn child_tap_cycles_despite_parent_group_echo() {
        // Regression: when a child group turns on, z2m publishes the
        // parent group as ON too (member-state aggregation).  The old
        // code's propagate_to_descendants inside handle_group_state
        // cleared last_press_at on the child, killing its cycle window.
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());

        // 1. Press child button → cooker turns on, scene 1.
        let a1 = c.handle_event(Event::TapAction {
            action: None, device: "hue-ts-foo".into(), button: 2, ts: clk.now(),
        });
        assert_eq!(a1, vec![Action::new("hue-lz-kitchen-cooker", Payload::scene_recall(1))]);
        assert!(c.state_for("kitchen-cooker").unwrap().last_press_at.is_some());

        // 2. z2m parent group echo arrives (parent was off → now on).
        clk.advance(Duration::from_millis(80));
        c.handle_event(Event::GroupState {
            group: "hue-lz-kitchen-all".into(), on: true, ts: clk.now(),
        });

        // Child's cycle state must survive the parent echo.
        let s = c.state_for("kitchen-cooker").unwrap();
        assert!(s.physically_on);
        assert!(s.last_press_at.is_some(), "parent group echo must not clear child's last_press_at");

        // 3. Press child button again within cycle window → should cycle.
        clk.advance(Duration::from_millis(200));
        let a2 = c.handle_event(Event::TapAction {
            action: None, device: "hue-ts-foo".into(), button: 2, ts: clk.now(),
        });
        assert_eq!(
            a2, vec![Action::new("hue-lz-kitchen-cooker", Payload::scene_recall(2))],
            "second press within cycle window must advance to scene 2, not turn off"
        );
        assert_eq!(c.state_for("kitchen-cooker").unwrap().cycle_idx, 1);
    }

    #[test]
    fn parent_group_off_echo_propagates_physical_state_to_children() {
        // Soft propagation must still update physically_on on off.
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());

        // Turn on child.
        c.handle_event(Event::TapAction {
            action: None, device: "hue-ts-foo".into(), button: 2, ts: clk.now(),
        });
        assert!(c.state_for("kitchen-cooker").unwrap().physically_on);

        // z2m publishes parent group ON (member-state aggregation).
        clk.advance(Duration::from_millis(80));
        c.handle_event(Event::GroupState {
            group: "hue-lz-kitchen-all".into(), on: true, ts: clk.now(),
        });

        // Parent group echo: off (e.g. someone turned off all via z2m UI).
        clk.advance(Duration::from_millis(100));
        c.handle_event(Event::GroupState {
            group: "hue-lz-kitchen-all".into(), on: false, ts: clk.now(),
        });

        // Children must be marked off.
        assert!(!c.state_for("kitchen-cooker").unwrap().physically_on);
        assert!(!c.state_for("kitchen-dining").unwrap().physically_on);
    }

    // ---- time-of-day slot dispatch --------------------------------------

    #[test]
    fn cycle_uses_active_slot_at_press_time() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        let day_press = c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::OnPressRelease, ts: clk.now() });
        assert_eq!(day_press, vec![Action::new("hue-lz-study", Payload::scene_recall(1))]);
        c.set_physical_state("study", false);
        clk.set_hour(2);
        let night_press = c.handle_event(Event::SwitchAction { device: "hue-s-study".into(), action: SwitchAction::OnPressRelease, ts: clk.now() });
        assert_eq!(night_press, vec![Action::new("hue-lz-study", Payload::scene_recall(3))]);
    }

    // ---- plug / action rule tests ---------------------------------------

    fn plug_dev(ieee: &str, variant: &str, caps: &[&str]) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Plug {
            common: CommonFields { ieee_address: ieee.into(), description: None, options: BTreeMap::new() },
            variant: variant.into(),
            capabilities: caps.iter().map(|s| s.to_string()).collect(),
            protocol: crate::config::catalog::PlugProtocol::default(),
            node_id: None,
        }
    }

    use crate::config::{ActionRule, Effect, Trigger};

    fn plug_controller(clock: Arc<FakeClock>, actions: Vec<ActionRule>) -> Controller {
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([
                ("hue-l-a".into(), light("0xa")),
                ("hue-ts-office".into(), tap_dev("0x1")),
                ("hue-s-office".into(), switch_dev("0x2")),
                ("z2m-p-printer".into(), plug_dev("0xf", "sonoff-power", &["on-off", "power"])),
                ("z2m-p-lamp".into(), plug_dev("0xe", "sonoff-basic", &["on-off"])),
            ]),
            rooms: vec![Room {
                name: "office".into(), group_name: "hue-lz-office".into(), id: 1,
                members: vec!["hue-l-a/11".into()], parent: None, devices: vec![],
                scenes: day_scenes(vec![1, 2]), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 0,
            }],
            actions,
            defaults: Defaults::default(),
            heating: None,
            location: None,
        };
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        Controller::new(topo, clock, cfg.defaults, None)
    }

    #[test]
    fn tap_toggle_action_toggles_plug() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![ActionRule {
            name: "printer-toggle".into(),
            trigger: Trigger::Tap { action: None, device: "hue-ts-office".into(), button: 3 },
            effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-printer".into() },
        }]);
        let actions = c.handle_event(Event::TapAction { action: None, device: "hue-ts-office".into(), button: 3, ts: clk.now() });
        assert!(actions.iter().any(|a| *a == Action::for_device("z2m-p-printer", Payload::device_on())));
        assert!(c.plug_state_for("z2m-p-printer").unwrap().on);
        clk.advance(Duration::from_secs(2));
        let actions = c.handle_event(Event::TapAction { action: None, device: "hue-ts-office".into(), button: 3, ts: clk.now() });
        assert!(actions.iter().any(|a| *a == Action::for_device("z2m-p-printer", Payload::device_off())));
        assert!(!c.plug_state_for("z2m-p-printer").unwrap().on);
    }

    #[test]
    fn switch_on_off_actions() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![
            ActionRule { name: "lamp-on".into(), trigger: Trigger::SwitchOn { device: "hue-s-office".into() }, effect: Effect::TurnOn { target: "z2m-p-lamp".into() } },
            ActionRule { name: "lamp-off".into(), trigger: Trigger::SwitchOff { device: "hue-s-office".into() }, effect: Effect::TurnOff { target: "z2m-p-lamp".into() } },
        ]);
        let actions = c.handle_event(Event::SwitchAction { device: "hue-s-office".into(), action: SwitchAction::OnPressRelease, ts: clk.now() });
        assert!(actions.iter().any(|a| *a == Action::for_device("z2m-p-lamp", Payload::device_on())));
        assert!(c.plug_state_for("z2m-p-lamp").unwrap().on);
        let actions = c.handle_event(Event::SwitchAction { device: "hue-s-office".into(), action: SwitchAction::OffPressRelease, ts: clk.now() });
        assert!(actions.iter().any(|a| *a == Action::for_device("z2m-p-lamp", Payload::device_off())));
        assert!(!c.plug_state_for("z2m-p-lamp").unwrap().on);
    }

    #[test]
    fn kill_switch_fires_after_holdoff() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![ActionRule {
            name: "printer-kill".into(),
            trigger: Trigger::PowerBelow { device: "z2m-p-printer".into(), watts: 5.0, for_seconds: 60 },
            effect: Effect::TurnOff { target: "z2m-p-printer".into() },
        }]);
        c.set_plug_state("z2m-p-printer", true);
        let actions = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(100.0), ts: clk.now() });
        assert!(actions.is_empty());
        assert!(!c.is_kill_switch_idle("printer-kill"));
        clk.advance(Duration::from_secs(10));
        let actions = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(2.0), ts: clk.now() });
        assert!(actions.is_empty());
        assert!(c.is_kill_switch_idle("printer-kill"));
        clk.advance(Duration::from_secs(30));
        let actions = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(2.0), ts: clk.now() });
        assert!(actions.is_empty());
        clk.advance(Duration::from_secs(31));
        let actions = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(2.0), ts: clk.now() });
        assert_eq!(actions, vec![Action::for_device("z2m-p-printer", Payload::device_off())]);
        assert!(!c.plug_state_for("z2m-p-printer").unwrap().on);
    }

    #[test]
    fn kill_switch_resets_on_power_recovery() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![ActionRule {
            name: "printer-kill".into(),
            trigger: Trigger::PowerBelow { device: "z2m-p-printer".into(), watts: 5.0, for_seconds: 60 },
            effect: Effect::TurnOff { target: "z2m-p-printer".into() },
        }]);
        c.set_plug_state("z2m-p-printer", true);
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(100.0), ts: clk.now() });
        clk.advance(Duration::from_secs(1));
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(2.0), ts: clk.now() });
        assert!(c.is_kill_switch_idle("printer-kill"));
        clk.advance(Duration::from_secs(30));
        let actions = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(100.0), ts: clk.now() });
        assert!(actions.is_empty());
        assert!(!c.is_kill_switch_idle("printer-kill"));
        clk.advance(Duration::from_secs(60));
        let actions = c.handle_event(Event::Tick { ts: clk.now() });
        assert!(actions.is_empty());
    }

    #[test]
    fn kill_switch_rearms_after_manual_on() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![
            ActionRule { name: "printer-toggle".into(), trigger: Trigger::Tap { action: None, device: "hue-ts-office".into(), button: 3 }, effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-printer".into() } },
            ActionRule { name: "printer-kill".into(), trigger: Trigger::PowerBelow { device: "z2m-p-printer".into(), watts: 5.0, for_seconds: 10 }, effect: Effect::TurnOff { target: "z2m-p-printer".into() } },
        ]);
        let _ = c.handle_event(Event::TapAction { action: None, device: "hue-ts-office".into(), button: 3, ts: clk.now() });
        assert!(c.plug_state_for("z2m-p-printer").unwrap().on);
        clk.advance(Duration::from_secs(1));
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(100.0), ts: clk.now() });
        clk.advance(Duration::from_secs(1));
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(1.0), ts: clk.now() });
        clk.advance(Duration::from_secs(11));
        let actions = c.handle_event(Event::Tick { ts: clk.now() });
        assert_eq!(actions, vec![Action::for_device("z2m-p-printer", Payload::device_off())]);
        assert!(!c.plug_state_for("z2m-p-printer").unwrap().on);
        clk.advance(Duration::from_secs(1));
        let actions = c.handle_event(Event::TapAction { action: None, device: "hue-ts-office".into(), button: 3, ts: clk.now() });
        assert!(actions.iter().any(|a| *a == Action::for_device("z2m-p-printer", Payload::device_on())));
        assert!(c.plug_state_for("z2m-p-printer").unwrap().on);
        assert!(!c.is_kill_switch_idle("printer-kill"));
    }

    #[test]
    fn tick_fires_kill_switch_without_plug_state_event() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![ActionRule {
            name: "printer-kill".into(),
            trigger: Trigger::PowerBelow { device: "z2m-p-printer".into(), watts: 5.0, for_seconds: 10 },
            effect: Effect::TurnOff { target: "z2m-p-printer".into() },
        }]);
        c.set_plug_state("z2m-p-printer", true);
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(100.0), ts: clk.now() });
        clk.advance(Duration::from_secs(1));
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(1.0), ts: clk.now() });
        clk.advance(Duration::from_secs(11));
        let actions = c.handle_event(Event::Tick { ts: clk.now() });
        assert_eq!(actions, vec![Action::for_device("z2m-p-printer", Payload::device_off())]);
    }

    #[test]
    fn plug_state_off_clears_idle() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![ActionRule {
            name: "printer-kill".into(),
            trigger: Trigger::PowerBelow { device: "z2m-p-printer".into(), watts: 5.0, for_seconds: 10 },
            effect: Effect::TurnOff { target: "z2m-p-printer".into() },
        }]);
        c.set_plug_state("z2m-p-printer", true);
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(100.0), ts: clk.now() });
        clk.advance(Duration::from_secs(1));
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(1.0), ts: clk.now() });
        assert!(c.is_kill_switch_idle("printer-kill"));
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: false, power: Some(0.0), ts: clk.now() });
        assert!(!c.is_kill_switch_idle("printer-kill"));
    }

    #[test]
    fn kill_switch_disarms_on_controller_driven_off_on_cycle() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![
            ActionRule { name: "printer-toggle".into(), trigger: Trigger::Tap { action: None, device: "hue-ts-office".into(), button: 3 }, effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-printer".into() } },
            ActionRule { name: "printer-kill".into(), trigger: Trigger::PowerBelow { device: "z2m-p-printer".into(), watts: 5.0, for_seconds: 10 }, effect: Effect::TurnOff { target: "z2m-p-printer".into() } },
        ]);
        let _ = c.handle_event(Event::TapAction { action: None, device: "hue-ts-office".into(), button: 3, ts: clk.now() });
        assert!(c.plug_state_for("z2m-p-printer").unwrap().on);
        clk.advance(Duration::from_secs(1));
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(100.0), ts: clk.now() });
        clk.advance(Duration::from_secs(1));
        let actions = c.handle_event(Event::TapAction { action: None, device: "hue-ts-office".into(), button: 3, ts: clk.now() });
        assert!(actions.iter().any(|a| a.payload == Payload::device_off()));
        assert!(!c.plug_state_for("z2m-p-printer").unwrap().on);
        clk.advance(Duration::from_secs(1));
        let _ = c.handle_event(Event::TapAction { action: None, device: "hue-ts-office".into(), button: 3, ts: clk.now() });
        assert!(c.plug_state_for("z2m-p-printer").unwrap().on);
        clk.advance(Duration::from_secs(1));
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(2.0), ts: clk.now() });
        assert!(!c.is_kill_switch_idle("printer-kill"), "stale arming must not survive controller-driven off/on cycle");
    }

    #[test]
    fn kill_switch_trips_after_startup_with_plug_already_below_threshold() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![ActionRule {
            name: "printer-kill".into(),
            trigger: Trigger::PowerBelow { device: "z2m-p-printer".into(), watts: 5.0, for_seconds: 10 },
            effect: Effect::TurnOff { target: "z2m-p-printer".into() },
        }]);
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(2.0), ts: clk.now() });
        assert!(c.is_kill_switch_idle("printer-kill"), "auto-arm on first ON must seed idle when power is below threshold");
        c.arm_kill_switches_for_active_plugs(clk.now());
        assert!(c.is_kill_switch_idle("printer-kill"));
        clk.advance(Duration::from_secs(11));
        let actions = c.handle_event(Event::Tick { ts: clk.now() });
        assert_eq!(actions.len(), 1);
        assert!(!c.plug_state_for("z2m-p-printer").unwrap().on);
    }

    #[test]
    fn kill_switch_startup_zwave_split_event_power_before_switch() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![ActionRule {
            name: "printer-kill".into(),
            trigger: Trigger::PowerBelow { device: "z2m-p-printer".into(), watts: 5.0, for_seconds: 10 },
            effect: Effect::TurnOff { target: "z2m-p-printer".into() },
        }]);
        let _ = c.handle_event(Event::PlugPowerUpdate { device: "z2m-p-printer".into(), watts: 2.0, ts: clk.now() });
        assert_eq!(c.plug_state_for("z2m-p-printer").unwrap().last_power, Some(2.0), "power-only update must not clear last_power when on is unknown");
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: None, ts: clk.now() });
        assert!(c.is_kill_switch_idle("printer-kill"), "auto-arm must seed idle from out-of-order meter reading at startup");
        c.arm_kill_switches_for_active_plugs(clk.now());
        clk.advance(Duration::from_secs(11));
        let actions = c.handle_event(Event::Tick { ts: clk.now() });
        assert_eq!(actions.len(), 1);
        assert!(!c.plug_state_for("z2m-p-printer").unwrap().on);
    }

    #[test]
    fn kill_switch_startup_late_switch_response_after_arming() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![ActionRule {
            name: "printer-kill".into(),
            trigger: Trigger::PowerBelow { device: "z2m-p-printer".into(), watts: 5.0, for_seconds: 10 },
            effect: Effect::TurnOff { target: "z2m-p-printer".into() },
        }]);
        let _ = c.handle_event(Event::PlugPowerUpdate { device: "z2m-p-printer".into(), watts: 2.0, ts: clk.now() });
        c.arm_kill_switches_for_active_plugs(clk.now());
        assert!(!c.is_kill_switch_idle("printer-kill"));
        clk.advance(Duration::from_secs(1));
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: None, ts: clk.now() });
        assert!(c.is_kill_switch_idle("printer-kill"), "auto-arm must seed idle from out-of-order meter reading");
        clk.advance(Duration::from_secs(11));
        let actions = c.handle_event(Event::Tick { ts: clk.now() });
        assert_eq!(actions.len(), 1);
        assert!(!c.plug_state_for("z2m-p-printer").unwrap().on);
    }

    #[test]
    fn kill_switch_does_not_retrip_before_warmup() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![ActionRule {
            name: "printer-kill".into(),
            trigger: Trigger::PowerBelow { device: "z2m-p-printer".into(), watts: 5.0, for_seconds: 10 },
            effect: Effect::TurnOff { target: "z2m-p-printer".into() },
        }]);
        c.set_plug_state("z2m-p-printer", true);
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(100.0), ts: clk.now() });
        clk.advance(Duration::from_secs(1));
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(1.0), ts: clk.now() });
        clk.advance(Duration::from_secs(11));
        let actions = c.handle_event(Event::Tick { ts: clk.now() });
        assert_eq!(actions.len(), 1);
        assert!(!c.plug_state_for("z2m-p-printer").unwrap().on);
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(2.0), ts: clk.now() });
        assert!(!c.is_kill_switch_idle("printer-kill"), "kill switch must not track idle before first above-threshold reading");
        clk.advance(Duration::from_secs(11));
        let actions = c.handle_event(Event::Tick { ts: clk.now() });
        assert!(actions.is_empty(), "must not retrip without warmup");
        assert!(c.plug_state_for("z2m-p-printer").unwrap().on);
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(100.0), ts: clk.now() });
        clk.advance(Duration::from_secs(1));
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(1.0), ts: clk.now() });
        assert!(c.is_kill_switch_idle("printer-kill"));
        clk.advance(Duration::from_secs(11));
        let actions = c.handle_event(Event::Tick { ts: clk.now() });
        assert_eq!(actions.len(), 1);
        assert!(!c.plug_state_for("z2m-p-printer").unwrap().on);
    }

    #[test]
    fn unrelated_switch_action_does_not_trigger_plug() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![ActionRule {
            name: "lamp-on".into(),
            trigger: Trigger::SwitchOn { device: "hue-s-office".into() },
            effect: Effect::TurnOn { target: "z2m-p-lamp".into() },
        }]);
        let actions = c.handle_event(Event::SwitchAction { device: "hue-s-office".into(), action: SwitchAction::UpPressRelease, ts: clk.now() });
        assert!(!actions.iter().any(|a| matches!(a.target, crate::domain::action::ActionTarget::Device(_))));
    }

    // ---- At trigger fires daily -----------------------------------------

    #[test]
    fn at_trigger_fires_again_next_day() {
        let clk = Arc::new(FakeClock::new(22));
        clk.set_minute(59);
        let mut c = plug_controller(clk.clone(), vec![ActionRule {
            name: "nightly-off".into(),
            trigger: Trigger::At { time: fixed_time(23, 0) },
            effect: Effect::TurnOff { target: "z2m-p-printer".into() },
        }]);
        c.set_plug_state("z2m-p-printer", true);
        let actions = c.handle_event(Event::Tick { ts: clk.now() });
        assert!(actions.is_empty());
        clk.set_hour(23); clk.set_minute(0); clk.advance(Duration::from_secs(60));
        let actions = c.handle_event(Event::Tick { ts: clk.now() });
        assert_eq!(actions.len(), 1);
        clk.advance(Duration::from_secs(5));
        let actions = c.handle_event(Event::Tick { ts: clk.now() });
        assert!(actions.is_empty());
        clk.set_minute(1); clk.advance(Duration::from_secs(60));
        let actions = c.handle_event(Event::Tick { ts: clk.now() });
        assert!(actions.is_empty());
        c.set_plug_state("z2m-p-printer", true);
        clk.set_minute(0); clk.advance(Duration::from_secs(86400));
        let actions = c.handle_event(Event::Tick { ts: clk.now() });
        assert_eq!(actions.len(), 1, "At trigger must fire again next day");
    }

    // ---- TurnOffAllZones effect -----------------------------------------

    #[test]
    fn turn_off_all_zones_only_touches_lit_rooms() {
        let clk = Arc::new(FakeClock::new(12));
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([("hue-l-a".into(), light("0xa")), ("hue-l-b".into(), light("0xb"))]),
            rooms: vec![
                Room { name: "room-a".into(), group_name: "hue-lz-a".into(), id: 1, members: vec!["hue-l-a/11".into()], parent: None, devices: vec![], scenes: day_scenes(vec![1]), off_transition_seconds: 0.5, motion_off_cooldown_seconds: 0 },
                Room { name: "room-b".into(), group_name: "hue-lz-b".into(), id: 2, members: vec!["hue-l-b/11".into()], parent: None, devices: vec![], scenes: day_scenes(vec![1]), off_transition_seconds: 1.0, motion_off_cooldown_seconds: 0 },
            ],
            actions: vec![ActionRule { name: "all-off".into(), trigger: Trigger::At { time: fixed_time(23, 0) }, effect: Effect::TurnOffAllZones }],
            defaults: Defaults::default(),
            heating: None,
            location: None,
        };
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        let mut c = Controller::new(topo, clk.clone(), cfg.defaults, None);
        c.set_physical_state("room-a", true);
        c.set_physical_state("room-b", false);
        clk.set_hour(23); clk.set_minute(0);
        let actions = c.handle_event(Event::Tick { ts: clk.now() });
        assert_eq!(actions.len(), 1);
        assert_eq!(actions[0].target_name(), "hue-lz-a");
        assert!(!c.state_for("room-a").unwrap().physically_on);
        assert!(!c.state_for("room-b").unwrap().physically_on);
    }

    // ---- action-rule-only switches in all_switch_names -------------------

    #[test]
    fn action_rule_only_switch_in_all_switch_names() {
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([
                ("hue-l-a".into(), light("0xa")),
                ("hue-s-standalone".into(), switch_dev("0x5")),
                ("z2m-p-lamp".into(), plug_dev("0xe", "sonoff-basic", &["on-off"])),
            ]),
            rooms: vec![Room {
                name: "empty-room".into(), group_name: "hue-lz-empty".into(), id: 1,
                members: vec!["hue-l-a/11".into()], parent: None, devices: vec![],
                scenes: day_scenes(vec![1]), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 0,
            }],
            actions: vec![ActionRule {
                name: "lamp-on".into(),
                trigger: Trigger::SwitchOn { device: "hue-s-standalone".into() },
                effect: Effect::TurnOn { target: "z2m-p-lamp".into() },
            }],
            defaults: Defaults::default(),
            heating: None,
            location: None,
        };
        let topo = Topology::build(&cfg).unwrap();
        assert!(topo.rooms_for_switch("hue-s-standalone").is_empty());
        assert!(topo.all_switch_names().contains("hue-s-standalone"), "action-rule-only switches must be included in all_switch_names");
    }
}
