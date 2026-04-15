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
//!   * [`room`]    — room-targeting effect executors (scene cycling,
//!     brightness, turn-off)
//!   * [`motion`]  — motion-sensor dispatch (occupancy gating,
//!     multi-sensor OR-gate, illuminance gate, cooldown)
//!   * [`plug`]    — plug state tracking and kill-switch integration
//!   * [`actions`] — scheduled `At` trigger evaluation
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
use std::time::{Duration, Instant};

use crate::config::Defaults;
use crate::config::switch_model::Gesture;
use crate::domain::action::{Action, Payload};
use crate::domain::event::Event;
use crate::domain::state::{PlugRuntimeState, ZoneState};
use crate::time::Clock;
use crate::topology::{RoomName, Topology};

use heating::HeatingController;
use kill_switch::KillSwitchEvaluator;

// ## Unified button dispatch
//
// All switch/tap events arrive as `Event::ButtonPress { device, button,
// gesture, ts }`. The controller dispatches via `bindings_for_button`
// which returns matching binding indexes for the (device, button, gesture)
// triple. Two deferral mechanisms exist:
//
//   * **Hardware double-tap suppression**: after a `DoubleTap` gesture,
//     subsequent `Press` events from the same (device, button) are
//     suppressed for `double_tap_suppression_seconds` to guard against
//     the Sonoff firmware's inter-sequence cooldown quirk.
//
//   * **Soft double-tap detection**: when a (device, button) pair has
//     `SoftDoubleTap` bindings, `Press` events are buffered for
//     `soft_double_tap_window_seconds`. A second `Press` within the
//     window fires `SoftDoubleTap` bindings; expiry flushes the
//     buffered press as a normal `Press`.

#[derive(Debug, Clone)]
struct PendingPress {
    device: String,
    button: String,
    ts: Instant,
    deadline: Instant,
}

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

    /// Last hardware double-tap timestamp per (device, button). After a
    /// hardware double-tap, press events from the same device+button are
    /// suppressed for `defaults.double_tap_suppression_seconds` to guard
    /// against the Sonoff firmware's inter-sequence cooldown sending
    /// spurious singles.
    last_double_tap: BTreeMap<(String, String), Instant>,

    /// Pending deferred press. When a (device, button) pair has
    /// soft_double_tap bindings, the first press is buffered here. If a
    /// second press arrives within the soft double-tap window, the
    /// pending is cancelled and SoftDoubleTap bindings fire. If the
    /// window expires (checked in `handle_tick`), the pending fires as
    /// a normal Press.
    pending_press: BTreeMap<(String, String), PendingPress>,

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
            last_double_tap: BTreeMap::new(),
            pending_press: BTreeMap::new(),
            heating,
            location,
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
            } => {
                self.handle_button_press(device, button, gesture, ts)
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

    /// Maximum kill-switch holdoff duration (seconds) for idle rules
    /// targeting `device`.
    pub fn kill_switch_holdoff_secs(&self, device: &str) -> Option<u64> {
        self.kill_switch.holdoff_secs(device)
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

    // ----- unified button press dispatch ------------------------------------

    /// Handle a button press event. Routes through hardware double-tap
    /// suppression, soft double-tap deferral, or direct dispatch
    /// depending on gesture and topology configuration.
    fn handle_button_press(
        &mut self,
        device: &str,
        button: &str,
        gesture: Gesture,
        ts: Instant,
    ) -> Vec<Action> {
        match gesture {
            Gesture::DoubleTap => {
                // Hardware double-tap. Record timestamp for suppression.
                self.last_double_tap
                    .insert((device.to_string(), button.to_string()), ts);
                // Fire double_tap bindings directly.
                self.dispatch_bindings(device, button, Gesture::DoubleTap, ts)
            }
            Gesture::Press => {
                // Check hardware double-tap suppression (Sonoff quirk).
                if self.topology.is_hw_double_tap_button(device, button) {
                    if let Some(&last_dt) = self
                        .last_double_tap
                        .get(&(device.to_string(), button.to_string()))
                    {
                        let window = Duration::from_secs_f64(
                            self.defaults.double_tap_suppression_seconds,
                        );
                        if ts.duration_since(last_dt) < window {
                            tracing::debug!(
                                device,
                                button,
                                "suppressing press within double-tap suppression window"
                            );
                            return Vec::new();
                        }
                    }
                }
                // Check if soft-double-tap deferral is needed.
                if self.topology.is_soft_double_tap_button(device, button) {
                    self.handle_soft_double_tap_press(device, button, ts)
                } else {
                    self.dispatch_bindings(device, button, Gesture::Press, ts)
                }
            }
            Gesture::SoftDoubleTap => {
                // This gesture is synthesized by the controller, never
                // from MQTT. Should not arrive here.
                Vec::new()
            }
            other => {
                // Hold, HoldRelease — dispatch directly, no deferral.
                self.dispatch_bindings(device, button, other, ts)
            }
        }
    }

    /// Handle a press event for a button that has soft-double-tap
    /// bindings. Buffers the first press; fires SoftDoubleTap on the
    /// second press within the window; flushes as Press on expiry.
    fn handle_soft_double_tap_press(
        &mut self,
        device: &str,
        button: &str,
        ts: Instant,
    ) -> Vec<Action> {
        let key = (device.to_string(), button.to_string());
        if let Some(pending) = self.pending_press.remove(&key) {
            let window =
                Duration::from_secs_f64(self.defaults.soft_double_tap_window_seconds);
            if ts.duration_since(pending.ts) <= window {
                tracing::info!(
                    device,
                    button,
                    elapsed_ms = ts.duration_since(pending.ts).as_millis() as u64,
                    "soft double-tap detected"
                );
                return self.dispatch_bindings(
                    device,
                    button,
                    Gesture::SoftDoubleTap,
                    ts,
                );
            }
            // Outside window — flush stale pending as press, then handle
            // new press (which also needs deferral).
            let mut out = self.dispatch_bindings(
                &pending.device,
                &pending.button,
                Gesture::Press,
                pending.ts,
            );
            let window =
                Duration::from_secs_f64(self.defaults.soft_double_tap_window_seconds);
            self.pending_press.insert(
                key,
                PendingPress {
                    device: device.to_string(),
                    button: button.to_string(),
                    ts,
                    deadline: ts + window,
                },
            );
            return out;
        }
        // First press — buffer it.
        let window =
            Duration::from_secs_f64(self.defaults.soft_double_tap_window_seconds);
        tracing::debug!(
            device,
            button,
            window_ms = window.as_millis() as u64,
            "deferring press for soft double-tap detection"
        );
        self.pending_press.insert(
            key,
            PendingPress {
                device: device.to_string(),
                button: button.to_string(),
                ts,
                deadline: ts + window,
            },
        );
        Vec::new()
    }

    /// Unified binding dispatch. Looks up matching bindings for the
    /// (device, button, gesture) triple and executes their effects.
    fn dispatch_bindings(
        &mut self,
        device: &str,
        button: &str,
        gesture: Gesture,
        ts: Instant,
    ) -> Vec<Action> {
        let indexes: Vec<usize> = self
            .topology
            .bindings_for_button(device, button, gesture)
            .to_vec();
        let bindings: Vec<(String, crate::config::Effect)> = indexes
            .iter()
            .map(|&idx| {
                let b = &self.topology.bindings()[idx];
                (b.name.clone(), b.effect.clone())
            })
            .collect();
        let mut out = Vec::new();
        for (name, effect) in &bindings {
            out.extend(self.execute_effect(name, effect, ts));
        }
        out
    }

    /// Execute a single effect. Handles both room-targeting and
    /// device-targeting effect variants.
    fn execute_effect(
        &mut self,
        rule_name: &str,
        effect: &crate::config::Effect,
        ts: Instant,
    ) -> Vec<Action> {
        use crate::config::Effect;
        match effect {
            Effect::SceneCycle { room } => self.execute_scene_cycle(room, ts),
            Effect::SceneToggleCycle { room } => {
                self.execute_scene_toggle_cycle(room, ts)
            }
            Effect::TurnOffRoom { room } => self.execute_turn_off_room(room, ts),
            Effect::BrightnessStep {
                room,
                step,
                transition,
            } => self.execute_brightness_step(room, *step, *transition),
            Effect::BrightnessMove { room, rate } => {
                self.execute_brightness_move(room, *rate)
            }
            Effect::BrightnessStop { room } => self.execute_brightness_stop(room),
            Effect::Toggle {
                target,
                confirm_off_seconds,
            } => {
                let plug_state =
                    self.plug_states.entry(target.to_string()).or_default();
                if plug_state.on {
                    if let Some(window) = confirm_off_seconds {
                        let window_dur = Duration::from_secs_f64(*window);
                        if let Some(pending_ts) =
                            self.confirm_off_pending.remove(rule_name)
                        {
                            if ts.duration_since(pending_ts) <= window_dur {
                                tracing::info!(
                                    rule = rule_name,
                                    target = target.as_str(),
                                    "action rule → confirm-off: second tap, turning off"
                                );
                                plug_state.on = false;
                                plug_state.seen_explicit_off = true;
                                plug_state.last_power = None;
                                self.kill_switch.on_plug_off(target);
                                return vec![Action::for_device(
                                    target,
                                    Payload::device_off(),
                                )];
                            }
                        }
                        tracing::info!(
                            rule = rule_name,
                            target = target.as_str(),
                            window_seconds = window,
                            "action rule → confirm-off: armed, tap again to turn off"
                        );
                        self.confirm_off_pending
                            .insert(rule_name.to_string(), ts);
                        return Vec::new();
                    }
                }
                self.confirm_off_pending.remove(rule_name);
                let new_on = !plug_state.on;
                let payload = if new_on {
                    Payload::device_on()
                } else {
                    Payload::device_off()
                };
                tracing::info!(
                    rule = rule_name,
                    target = target.as_str(),
                    from = plug_state.on,
                    to = new_on,
                    "action rule → toggle plug"
                );
                plug_state.on = new_on;
                if !new_on {
                    plug_state.seen_explicit_off = true;
                    plug_state.last_power = None;
                    self.kill_switch.on_plug_off(target);
                } else if plug_state.seen_explicit_off {
                    plug_state.last_power = None;
                    plug_state.seen_explicit_off = false;
                }
                vec![Action::for_device(target, payload)]
            }
            Effect::TurnOn { target } => {
                let plug_state =
                    self.plug_states.entry(target.to_string()).or_default();
                tracing::info!(
                    rule = rule_name,
                    target = target.as_str(),
                    "action rule → turn on plug"
                );
                if plug_state.seen_explicit_off {
                    plug_state.last_power = None;
                }
                plug_state.on = true;
                plug_state.seen_explicit_off = false;
                vec![Action::for_device(target, Payload::device_on())]
            }
            Effect::TurnOff { target } => {
                let plug_state =
                    self.plug_states.entry(target.to_string()).or_default();
                tracing::info!(
                    rule = rule_name,
                    target = target.as_str(),
                    "action rule → turn off plug"
                );
                plug_state.on = false;
                plug_state.seen_explicit_off = true;
                plug_state.last_power = None;
                self.kill_switch.on_plug_off(target);
                vec![Action::for_device(target, Payload::device_off())]
            }
            Effect::TurnOffAllZones => {
                tracing::info!(rule = rule_name, "action rule → turn off all zones");
                let mut out = Vec::new();
                for room in self.topology.rooms() {
                    let state =
                        self.states.entry(room.name.clone()).or_default();
                    if state.physically_on {
                        tracing::info!(
                            rule = rule_name,
                            room = room.name.as_str(),
                            group = room.group_name.as_str(),
                            "turning off zone"
                        );
                        state.physically_on = false;
                        state.motion_owned = false;
                        state.cycle_idx = 0;
                        state.last_off_at = Some(ts);
                        out.push(Action::new(
                            &room.group_name,
                            Payload::state_off(room.off_transition_seconds),
                        ));
                    }
                }
                out
            }
        }
    }

    /// Earliest deadline among pending presses, if any.
    pub fn next_press_deadline(&self) -> Option<Instant> {
        self.pending_press.values().map(|p| p.deadline).min()
    }

    /// Flush all pending presses whose deadline has passed.
    fn flush_pending_presses(&mut self, ts: Instant) -> Vec<Action> {
        let expired: Vec<_> = self
            .pending_press
            .iter()
            .filter(|(_, p)| ts >= p.deadline)
            .map(|(k, p)| (k.clone(), p.clone()))
            .collect();
        let mut out = Vec::new();
        for (key, pending) in expired {
            self.pending_press.remove(&key);
            tracing::debug!(
                device = %pending.device,
                button = %pending.button,
                "flushing deferred single press"
            );
            out.extend(self.dispatch_bindings(
                &pending.device,
                &pending.button,
                Gesture::Press,
                pending.ts,
            ));
        }
        out
    }

    // ----- tick handler (dispatches to actions + kill_switch) ---------------

    fn handle_tick(&mut self, ts: Instant) -> Vec<Action> {
        let mut out = self.flush_pending_presses(ts);
        out.extend(self.evaluate_at_triggers(ts));

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
        Binding, CommonFields, Config, Defaults, DeviceCatalogEntry, Effect, Room,
        SwitchModel, Trigger,
    };
    use crate::config::switch_model::ActionMapping;
    use crate::domain::action::Payload;
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
        DeviceCatalogEntry::Switch { common: CommonFields { ieee_address: ieee.into(), description: None, options: BTreeMap::new() }, model: "test-dimmer".into() }
    }
    fn tap_dev(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Switch { common: CommonFields { ieee_address: ieee.into(), description: None, options: BTreeMap::new() }, model: "test-tap".into() }
    }
    fn motion(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::MotionSensor {
            common: CommonFields { ieee_address: ieee.into(), description: None, options: BTreeMap::new() },
            occupancy_timeout_seconds: 60,
            max_illuminance: None,
        }
    }

    /// A Hue dimmer switch model: on, off, up, down buttons with
    /// press, hold, and hold_release gestures.
    fn test_dimmer_model() -> SwitchModel {
        SwitchModel {
            buttons: vec!["on".into(), "off".into(), "up".into(), "down".into()],
            z2m_action_map: BTreeMap::from([
                ("on_press_release".into(), ActionMapping { button: "on".into(), gesture: Gesture::Press }),
                ("off_press_release".into(), ActionMapping { button: "off".into(), gesture: Gesture::Press }),
                ("up_press_release".into(), ActionMapping { button: "up".into(), gesture: Gesture::Press }),
                ("up_hold".into(), ActionMapping { button: "up".into(), gesture: Gesture::Hold }),
                ("up_hold_release".into(), ActionMapping { button: "up".into(), gesture: Gesture::HoldRelease }),
                ("down_press_release".into(), ActionMapping { button: "down".into(), gesture: Gesture::Press }),
                ("down_hold".into(), ActionMapping { button: "down".into(), gesture: Gesture::Hold }),
                ("down_hold_release".into(), ActionMapping { button: "down".into(), gesture: Gesture::HoldRelease }),
            ]),
        }
    }

    /// A Hue Tap model: buttons 1-4, press only.
    fn test_tap_model() -> SwitchModel {
        SwitchModel {
            buttons: vec!["1".into(), "2".into(), "3".into(), "4".into()],
            z2m_action_map: BTreeMap::from([
                ("press_1".into(), ActionMapping { button: "1".into(), gesture: Gesture::Press }),
                ("press_2".into(), ActionMapping { button: "2".into(), gesture: Gesture::Press }),
                ("press_3".into(), ActionMapping { button: "3".into(), gesture: Gesture::Press }),
                ("press_4".into(), ActionMapping { button: "4".into(), gesture: Gesture::Press }),
            ]),
        }
    }

    /// A Sonoff SNZB-01M model with hardware double-tap.
    fn test_sonoff_model() -> SwitchModel {
        SwitchModel {
            buttons: vec!["1".into()],
            z2m_action_map: BTreeMap::from([
                ("single".into(), ActionMapping { button: "1".into(), gesture: Gesture::Press }),
                ("double".into(), ActionMapping { button: "1".into(), gesture: Gesture::DoubleTap }),
            ]),
        }
    }

    fn test_switch_models() -> BTreeMap<String, SwitchModel> {
        BTreeMap::from([
            ("test-dimmer".into(), test_dimmer_model()),
            ("test-tap".into(), test_tap_model()),
            ("test-sonoff".into(), test_sonoff_model()),
        ])
    }

    fn btn_at(device: &str, button: &str, gesture: Gesture, ts: std::time::Instant) -> Event {
        Event::ButtonPress {
            device: device.into(),
            button: button.into(),
            gesture,
            ts,
        }
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
            switch_models: test_switch_models(),
            rooms: vec![
                Room {
                    name: "kitchen-cooker".into(), group_name: "hue-lz-kitchen-cooker".into(), id: 1,
                    members: vec!["hue-l-cooker/11".into()], parent: Some("kitchen-all".into()),
                    motion_sensors: vec![],
                    scenes: day_scenes(vec![1, 2, 3]), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 0,
                },
                Room {
                    name: "kitchen-dining".into(), group_name: "hue-lz-kitchen-dining".into(), id: 2,
                    members: vec!["hue-l-dining/11".into()], parent: Some("kitchen-all".into()),
                    motion_sensors: vec![],
                    scenes: day_scenes(vec![1, 2, 3]), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 0,
                },
                Room {
                    name: "kitchen-all".into(), group_name: "hue-lz-kitchen-all".into(), id: 3,
                    members: vec!["hue-l-cooker/11".into(), "hue-l-dining/11".into(), "hue-l-empty/11".into()],
                    parent: None, motion_sensors: vec![],
                    scenes: day_scenes(vec![1, 2, 3]), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 0,
                },
            ],
            bindings: vec![
                Binding { name: "kitchen-cooker-press".into(), trigger: Trigger::Button { device: "hue-ts-foo".into(), button: "2".into(), gesture: Gesture::Press }, effect: Effect::SceneToggleCycle { room: "kitchen-cooker".into() } },
                Binding { name: "kitchen-dining-press".into(), trigger: Trigger::Button { device: "hue-ts-foo".into(), button: "3".into(), gesture: Gesture::Press }, effect: Effect::SceneToggleCycle { room: "kitchen-dining".into() } },
                Binding { name: "kitchen-all-press".into(), trigger: Trigger::Button { device: "hue-ts-foo".into(), button: "1".into(), gesture: Gesture::Press }, effect: Effect::SceneToggleCycle { room: "kitchen-all".into() } },
            ],
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
            switch_models: test_switch_models(),
            rooms: vec![Room {
                name: "study".into(), group_name: "hue-lz-study".into(), id: 1,
                members: vec!["hue-l-a/11".into()], parent: None,
                motion_sensors: vec!["hue-ms-study".into()],
                scenes: day_night_scenes(), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 30,
            }],
            bindings: vec![
                Binding { name: "study-on".into(), trigger: Trigger::Button { device: "hue-s-study".into(), button: "on".into(), gesture: Gesture::Press }, effect: Effect::SceneCycle { room: "study".into() } },
                Binding { name: "study-off".into(), trigger: Trigger::Button { device: "hue-s-study".into(), button: "off".into(), gesture: Gesture::Press }, effect: Effect::TurnOffRoom { room: "study".into() } },
                Binding { name: "study-up".into(), trigger: Trigger::Button { device: "hue-s-study".into(), button: "up".into(), gesture: Gesture::Press }, effect: Effect::BrightnessStep { room: "study".into(), step: 25, transition: 0.2 } },
                Binding { name: "study-down".into(), trigger: Trigger::Button { device: "hue-s-study".into(), button: "down".into(), gesture: Gesture::Press }, effect: Effect::BrightnessStep { room: "study".into(), step: -25, transition: 0.2 } },
                Binding { name: "study-up-hold".into(), trigger: Trigger::Button { device: "hue-s-study".into(), button: "up".into(), gesture: Gesture::Hold }, effect: Effect::BrightnessMove { room: "study".into(), rate: 40 } },
                Binding { name: "study-down-hold".into(), trigger: Trigger::Button { device: "hue-s-study".into(), button: "down".into(), gesture: Gesture::Hold }, effect: Effect::BrightnessMove { room: "study".into(), rate: -40 } },
                Binding { name: "study-up-hold-rel".into(), trigger: Trigger::Button { device: "hue-s-study".into(), button: "up".into(), gesture: Gesture::HoldRelease }, effect: Effect::BrightnessStop { room: "study".into() } },
                Binding { name: "study-down-hold-rel".into(), trigger: Trigger::Button { device: "hue-s-study".into(), button: "down".into(), gesture: Gesture::HoldRelease }, effect: Effect::BrightnessStop { room: "study".into() } },
            ],
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
        let actions = c.handle_event(btn_at("hue-ts-foo", "2", Gesture::Press, clk.now()));
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
        c.handle_event(btn_at("hue-ts-foo", "2", Gesture::Press, clk.now()));
        clk.advance(Duration::from_millis(200));
        let actions = c.handle_event(btn_at("hue-ts-foo", "2", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-cooker", Payload::scene_recall(2))]);
        assert_eq!(c.state_for("kitchen-cooker").unwrap().cycle_idx, 1);
    }

    #[test]
    fn tap_press_outside_window_expires_to_off() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        c.handle_event(btn_at("hue-ts-foo", "2", Gesture::Press, clk.now()));
        clk.advance(Duration::from_millis(1500));
        let actions = c.handle_event(btn_at("hue-ts-foo", "2", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-cooker", Payload::state_off(0.8))]);
        assert!(!c.state_for("kitchen-cooker").unwrap().physically_on);
    }

    #[test]
    fn tap_cycle_wraps_at_n() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        for _ in 0..3 {
            c.handle_event(btn_at("hue-ts-foo", "2", Gesture::Press, clk.now()));
            clk.advance(Duration::from_millis(100));
        }
        let actions = c.handle_event(btn_at("hue-ts-foo", "2", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-cooker", Payload::scene_recall(1))]);
    }

    // ---- parent/child propagation ----------------------------------------

    #[test]
    fn parent_on_then_child_press_toggles_child_off() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        let p = c.handle_event(btn_at("hue-ts-foo", "1", Gesture::Press, clk.now()));
        assert_eq!(p, vec![Action::new("hue-lz-kitchen-all", Payload::scene_recall(1))]);
        assert!(c.state_for("kitchen-cooker").unwrap().physically_on);
        assert!(c.state_for("kitchen-cooker").unwrap().last_press_at.is_none());
        clk.advance(Duration::from_millis(150));
        let actions = c.handle_event(btn_at("hue-ts-foo", "2", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-cooker", Payload::state_off(0.8))]);
        assert!(!c.state_for("kitchen-cooker").unwrap().physically_on);
    }

    #[test]
    fn parent_on_then_delayed_child_press_still_toggles_off() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        c.handle_event(btn_at("hue-ts-foo", "1", Gesture::Press, clk.now()));
        clk.advance(Duration::from_millis(2500));
        let actions = c.handle_event(btn_at("hue-ts-foo", "2", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-cooker", Payload::state_off(0.8))]);
    }

    #[test]
    fn parent_on_then_child_off_then_child_on_fresh() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        c.handle_event(btn_at("hue-ts-foo", "1", Gesture::Press, clk.now()));
        clk.advance(Duration::from_millis(100));
        c.handle_event(btn_at("hue-ts-foo", "2", Gesture::Press, clk.now()));
        clk.advance(Duration::from_millis(100));
        let actions = c.handle_event(btn_at("hue-ts-foo", "2", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-cooker", Payload::scene_recall(1))]);
    }

    #[test]
    fn child_press_does_not_alter_parent_state() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        c.handle_event(btn_at("hue-ts-foo", "2", Gesture::Press, clk.now()));
        clk.advance(Duration::from_millis(100));
        let actions = c.handle_event(btn_at("hue-ts-foo", "1", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-all", Payload::scene_recall(1))]);
    }

    #[test]
    fn parent_cycle_keeps_descendants_marked_on() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        c.handle_event(btn_at("hue-ts-foo", "1", Gesture::Press, clk.now()));
        clk.advance(Duration::from_millis(200));
        c.handle_event(btn_at("hue-ts-foo", "1", Gesture::Press, clk.now()));
        clk.advance(Duration::from_millis(200));
        let actions = c.handle_event(btn_at("hue-ts-foo", "2", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-cooker", Payload::state_off(0.8))]);
    }

    #[test]
    fn sibling_press_independent_of_other_sibling() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());
        c.handle_event(btn_at("hue-ts-foo", "2", Gesture::Press, clk.now()));
        clk.advance(Duration::from_millis(100));
        let actions = c.handle_event(btn_at("hue-ts-foo", "3", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-kitchen-dining", Payload::scene_recall(1))]);
    }

    // ---- wall switch on button -------------------------------------------

    #[test]
    fn wall_switch_on_press_from_off_publishes_first_scene() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        let actions = c.handle_event(btn_at("hue-s-study", "on", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-study", Payload::scene_recall(1))]);
        let s = c.state_for("study").unwrap();
        assert!(s.physically_on);
        assert_eq!(s.cycle_idx, 0);
    }

    #[test]
    fn wall_switch_on_press_within_window_cycles_scene() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        c.handle_event(btn_at("hue-s-study", "on", Gesture::Press, clk.now()));
        clk.advance(Duration::from_millis(200));
        let actions = c.handle_event(btn_at("hue-s-study", "on", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-study", Payload::scene_recall(2))]);
        assert_eq!(c.state_for("study").unwrap().cycle_idx, 1);
    }

    #[test]
    fn wall_switch_on_press_advances_cycle_with_no_time_component() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        let a1 = c.handle_event(btn_at("hue-s-study", "on", Gesture::Press, clk.now()));
        assert_eq!(a1, vec![Action::new("hue-lz-study", Payload::scene_recall(1))]);
        clk.advance(Duration::from_secs(60));
        let a2 = c.handle_event(btn_at("hue-s-study", "on", Gesture::Press, clk.now()));
        assert_eq!(a2, vec![Action::new("hue-lz-study", Payload::scene_recall(2))],
            "wall switch press should always advance the cycle, regardless of how long ago the previous press was");
        clk.advance(Duration::from_secs(300));
        let a3 = c.handle_event(btn_at("hue-s-study", "on", Gesture::Press, clk.now()));
        assert_eq!(a3, vec![Action::new("hue-lz-study", Payload::scene_recall(3))]);
        clk.advance(Duration::from_secs(10));
        let a4 = c.handle_event(btn_at("hue-s-study", "on", Gesture::Press, clk.now()));
        assert_eq!(a4, vec![Action::new("hue-lz-study", Payload::scene_recall(1))]);
    }

    #[test]
    fn wall_switch_off_press_resets_cycle_index() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        for _ in 0..3 {
            c.handle_event(btn_at("hue-s-study", "on", Gesture::Press, clk.now()));
            clk.advance(Duration::from_millis(100));
        }
        assert_eq!(c.state_for("study").unwrap().cycle_idx, 2);
        c.handle_event(btn_at("hue-s-study", "off", Gesture::Press, clk.now()));
        assert!(!c.state_for("study").unwrap().physically_on);
        let actions = c.handle_event(btn_at("hue-s-study", "on", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-study", Payload::scene_recall(1))]);
    }

    #[test]
    fn wall_switch_full_cycle_walks_all_scenes_then_wraps() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        let mut emitted: Vec<u8> = Vec::new();
        for _ in 0..4 {
            let actions = c.handle_event(btn_at("hue-s-study", "on", Gesture::Press, clk.now()));
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
        let actions = c.handle_event(btn_at("hue-s-study", "off", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-study", Payload::state_off(0.8))]);
    }

    #[test]
    fn wall_switch_brightness_up_press_release() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        let actions = c.handle_event(btn_at("hue-s-study", "up", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-study", Payload::brightness_step(25, 0.2))]);
    }

    #[test]
    fn wall_switch_brightness_down_press_release() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        let actions = c.handle_event(btn_at("hue-s-study", "down", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-study", Payload::brightness_step(-25, 0.2))]);
    }

    #[test]
    fn wall_switch_hold_and_release_brightness_move() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        let hold = c.handle_event(btn_at("hue-s-study", "up", Gesture::Hold, clk.now()));
        assert_eq!(hold, vec![Action::new("hue-lz-study", Payload::brightness_move(40))]);
        let release = c.handle_event(btn_at("hue-s-study", "up", Gesture::HoldRelease, clk.now()));
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
        c.handle_event(btn_at("hue-s-study", "on", Gesture::Press, clk.now()));
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
            switch_models: BTreeMap::new(),
            rooms: vec![Room {
                name: "study".into(), group_name: "hue-lz-study".into(), id: 1,
                members: vec!["hue-l-a/11".into()], parent: None,
                motion_sensors: vec!["hue-ms-study".into()],
                scenes: day_scenes(vec![1]), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 0,
            }],
            bindings: vec![], defaults: Defaults::default(), heating: None, location: None,
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
            switch_models: BTreeMap::new(),
            rooms: vec![Room {
                name: "study".into(), group_name: "hue-lz-study".into(), id: 1,
                members: vec!["hue-l-a/11".into()], parent: None,
                motion_sensors: vec!["hue-ms-study".into()],
                scenes: day_scenes(vec![1]), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 0,
            }],
            bindings: vec![], defaults: Defaults::default(), heating: None, location: None,
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
            switch_models: BTreeMap::new(),
            rooms: vec![Room {
                name: "hall".into(), group_name: "hue-lz-hall".into(), id: 1,
                members: vec!["hue-l-a/11".into()], parent: None,
                motion_sensors: vec!["hue-ms-a".into(), "hue-ms-b".into()],
                scenes: day_scenes(vec![1]), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 0,
            }],
            bindings: vec![], defaults: Defaults::default(), heating: None, location: None,
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

    // ---- hardware double-tap suppression ----------------------------------

    fn hw_double_tap_controller(clock: Arc<FakeClock>) -> Controller {
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([
                ("hue-l-a".into(), light("0xa")),
                ("sonoff-ts-foo".into(), DeviceCatalogEntry::Switch {
                    common: CommonFields { ieee_address: "0x1".into(), description: None, options: BTreeMap::new() },
                    model: "test-sonoff".into(),
                }),
            ]),
            switch_models: test_switch_models(),
            rooms: vec![Room {
                name: "bedroom".into(), group_name: "hue-lz-bedroom".into(), id: 1,
                members: vec!["hue-l-a/11".into()], parent: None,
                motion_sensors: vec![],
                scenes: day_night_scenes(), off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
            }],
            bindings: vec![
                Binding { name: "bedroom-press".into(), trigger: Trigger::Button { device: "sonoff-ts-foo".into(), button: "1".into(), gesture: Gesture::Press }, effect: Effect::SceneToggleCycle { room: "bedroom".into() } },
                Binding { name: "bedroom-double".into(), trigger: Trigger::Button { device: "sonoff-ts-foo".into(), button: "1".into(), gesture: Gesture::DoubleTap }, effect: Effect::SceneCycle { room: "bedroom".into() } },
            ],
            defaults: Defaults::default(),
            heating: None,
            location: None,
        };
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        Controller::new(topo, clock, cfg.defaults, None)
    }

    #[test]
    fn hw_double_tap_press_turns_on_first_scene() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = hw_double_tap_controller(clk.clone());
        let actions = c.handle_event(btn_at("sonoff-ts-foo", "1", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-bedroom", Payload::scene_recall(1))]);
        assert!(c.state_for("bedroom").unwrap().physically_on);
    }

    #[test]
    fn hw_double_tap_cycles_scenes() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = hw_double_tap_controller(clk.clone());
        // Turn on via press.
        c.handle_event(btn_at("sonoff-ts-foo", "1", Gesture::Press, clk.now()));
        // Double tap → advance to scene 2.
        let actions = c.handle_event(btn_at("sonoff-ts-foo", "1", Gesture::DoubleTap, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-bedroom", Payload::scene_recall(2))]);
        assert_eq!(c.state_for("bedroom").unwrap().cycle_idx, 1);
    }

    #[test]
    fn hw_double_tap_suppresses_press_within_cooldown() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = hw_double_tap_controller(clk.clone());
        // Turn on via press.
        c.handle_event(btn_at("sonoff-ts-foo", "1", Gesture::Press, clk.now()));
        // Double tap → advance scene.
        c.handle_event(btn_at("sonoff-ts-foo", "1", Gesture::DoubleTap, clk.now()));
        // Spurious press within 2 s cooldown → suppressed.
        clk.advance(Duration::from_millis(500));
        let actions = c.handle_event(btn_at("sonoff-ts-foo", "1", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![], "press within cooldown must be suppressed");
        assert!(c.state_for("bedroom").unwrap().physically_on, "room must stay on");
    }

    #[test]
    fn hw_double_tap_press_works_after_cooldown_expires() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = hw_double_tap_controller(clk.clone());
        // Turn on via press.
        c.handle_event(btn_at("sonoff-ts-foo", "1", Gesture::Press, clk.now()));
        // Double tap → advance scene.
        c.handle_event(btn_at("sonoff-ts-foo", "1", Gesture::DoubleTap, clk.now()));
        // Wait past the 2 s suppression window.
        clk.advance(Duration::from_secs(3));
        // Press → should toggle off normally.
        let actions = c.handle_event(btn_at("sonoff-ts-foo", "1", Gesture::Press, clk.now()));
        assert_eq!(actions, vec![Action::new("hue-lz-bedroom", Payload::state_off(0.8))]);
        assert!(!c.state_for("bedroom").unwrap().physically_on);
    }

    #[test]
    fn suppression_does_not_affect_non_hw_double_tap_buttons() {
        let clk = Arc::new(FakeClock::new(12));
        // kitchen_controller uses test-tap model which has no hardware double-tap.
        let mut c = kitchen_controller(clk.clone());
        // Press on button 1 → should work.
        let actions = c.handle_event(btn_at("hue-ts-foo", "1", Gesture::Press, clk.now()));
        assert!(!actions.is_empty(), "press on non-hw-double-tap button must not be suppressed");
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
            switch_models: test_switch_models(),
            rooms: vec![Room {
                name: "office".into(), group_name: "hue-lz-office".into(), id: 1,
                members: vec!["hue-l-a/11".into()], parent: None,
                motion_sensors: vec![],
                scenes: day_scenes(vec![1]), off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
            }],
            bindings: vec![], defaults: Defaults::default(), heating: None, location: None,
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
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());

        // 1. Press child button → cooker turns on, scene 1.
        let a1 = c.handle_event(btn_at("hue-ts-foo", "2", Gesture::Press, clk.now()));
        assert_eq!(a1, vec![Action::new("hue-lz-kitchen-cooker", Payload::scene_recall(1))]);
        assert!(c.state_for("kitchen-cooker").unwrap().last_press_at.is_some());

        // 2. z2m parent group echo arrives (parent was off → now on).
        clk.advance(Duration::from_millis(80));
        c.handle_event(Event::GroupState {
            group: "hue-lz-kitchen-all".into(), on: true, ts: clk.now(),
        });

        let s = c.state_for("kitchen-cooker").unwrap();
        assert!(s.physically_on);
        assert!(s.last_press_at.is_some(), "parent group echo must not clear child's last_press_at");

        // 3. Press child button again within cycle window → should cycle.
        clk.advance(Duration::from_millis(200));
        let a2 = c.handle_event(btn_at("hue-ts-foo", "2", Gesture::Press, clk.now()));
        assert_eq!(
            a2, vec![Action::new("hue-lz-kitchen-cooker", Payload::scene_recall(2))],
            "second press within cycle window must advance to scene 2, not turn off"
        );
        assert_eq!(c.state_for("kitchen-cooker").unwrap().cycle_idx, 1);
    }

    #[test]
    fn parent_group_off_echo_propagates_physical_state_to_children() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());

        c.handle_event(btn_at("hue-ts-foo", "2", Gesture::Press, clk.now()));
        assert!(c.state_for("kitchen-cooker").unwrap().physically_on);

        clk.advance(Duration::from_millis(80));
        c.handle_event(Event::GroupState {
            group: "hue-lz-kitchen-all".into(), on: true, ts: clk.now(),
        });

        clk.advance(Duration::from_millis(100));
        c.handle_event(Event::GroupState {
            group: "hue-lz-kitchen-all".into(), on: false, ts: clk.now(),
        });

        assert!(!c.state_for("kitchen-cooker").unwrap().physically_on);
        assert!(!c.state_for("kitchen-dining").unwrap().physically_on);
    }

    // ---- time-of-day slot dispatch --------------------------------------

    #[test]
    fn cycle_uses_active_slot_at_press_time() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        let day_press = c.handle_event(btn_at("hue-s-study", "on", Gesture::Press, clk.now()));
        assert_eq!(day_press, vec![Action::new("hue-lz-study", Payload::scene_recall(1))]);
        c.set_physical_state("study", false);
        clk.set_hour(2);
        let night_press = c.handle_event(btn_at("hue-s-study", "on", Gesture::Press, clk.now()));
        assert_eq!(night_press, vec![Action::new("hue-lz-study", Payload::scene_recall(3))]);
    }

    // ---- plug / binding tests -------------------------------------------

    fn plug_dev(ieee: &str, variant: &str, caps: &[&str]) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Plug {
            common: CommonFields { ieee_address: ieee.into(), description: None, options: BTreeMap::new() },
            variant: variant.into(),
            capabilities: caps.iter().map(|s| s.to_string()).collect(),
            protocol: crate::config::catalog::PlugProtocol::default(),
            node_id: None,
        }
    }

    fn plug_controller(clock: Arc<FakeClock>, bindings: Vec<Binding>) -> Controller {
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([
                ("hue-l-a".into(), light("0xa")),
                ("hue-ts-office".into(), tap_dev("0x1")),
                ("hue-s-office".into(), switch_dev("0x2")),
                ("z2m-p-printer".into(), plug_dev("0xf", "sonoff-power", &["on-off", "power"])),
                ("z2m-p-lamp".into(), plug_dev("0xe", "sonoff-basic", &["on-off"])),
            ]),
            switch_models: test_switch_models(),
            rooms: vec![Room {
                name: "office".into(), group_name: "hue-lz-office".into(), id: 1,
                members: vec!["hue-l-a/11".into()], parent: None, motion_sensors: vec![],
                scenes: day_scenes(vec![1, 2]), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 0,
            }],
            bindings,
            defaults: Defaults::default(),
            heating: None,
            location: None,
        };
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        Controller::new(topo, clock, cfg.defaults, None)
    }

    #[test]
    fn tap_toggle_binding_toggles_plug() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![Binding {
            name: "printer-toggle".into(),
            trigger: Trigger::Button { device: "hue-ts-office".into(), button: "3".into(), gesture: Gesture::Press },
            effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-printer".into() },
        }]);
        let actions = c.handle_event(btn_at("hue-ts-office", "3", Gesture::Press, clk.now()));
        assert!(actions.iter().any(|a| *a == Action::for_device("z2m-p-printer", Payload::device_on())));
        assert!(c.plug_state_for("z2m-p-printer").unwrap().on);
        clk.advance(Duration::from_secs(2));
        let actions = c.handle_event(btn_at("hue-ts-office", "3", Gesture::Press, clk.now()));
        assert!(actions.iter().any(|a| *a == Action::for_device("z2m-p-printer", Payload::device_off())));
        assert!(!c.plug_state_for("z2m-p-printer").unwrap().on);
    }

    #[test]
    fn switch_on_off_bindings() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![
            Binding { name: "lamp-on".into(), trigger: Trigger::Button { device: "hue-s-office".into(), button: "on".into(), gesture: Gesture::Press }, effect: Effect::TurnOn { target: "z2m-p-lamp".into() } },
            Binding { name: "lamp-off".into(), trigger: Trigger::Button { device: "hue-s-office".into(), button: "off".into(), gesture: Gesture::Press }, effect: Effect::TurnOff { target: "z2m-p-lamp".into() } },
        ]);
        let actions = c.handle_event(btn_at("hue-s-office", "on", Gesture::Press, clk.now()));
        assert!(actions.iter().any(|a| *a == Action::for_device("z2m-p-lamp", Payload::device_on())));
        assert!(c.plug_state_for("z2m-p-lamp").unwrap().on);
        let actions = c.handle_event(btn_at("hue-s-office", "off", Gesture::Press, clk.now()));
        assert!(actions.iter().any(|a| *a == Action::for_device("z2m-p-lamp", Payload::device_off())));
        assert!(!c.plug_state_for("z2m-p-lamp").unwrap().on);
    }

    #[test]
    fn kill_switch_fires_after_holdoff() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![Binding {
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
        let mut c = plug_controller(clk.clone(), vec![Binding {
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
            Binding { name: "printer-toggle".into(), trigger: Trigger::Button { device: "hue-ts-office".into(), button: "3".into(), gesture: Gesture::Press }, effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-printer".into() } },
            Binding { name: "printer-kill".into(), trigger: Trigger::PowerBelow { device: "z2m-p-printer".into(), watts: 5.0, for_seconds: 10 }, effect: Effect::TurnOff { target: "z2m-p-printer".into() } },
        ]);
        let _ = c.handle_event(btn_at("hue-ts-office", "3", Gesture::Press, clk.now()));
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
        let actions = c.handle_event(btn_at("hue-ts-office", "3", Gesture::Press, clk.now()));
        assert!(actions.iter().any(|a| *a == Action::for_device("z2m-p-printer", Payload::device_on())));
        assert!(c.plug_state_for("z2m-p-printer").unwrap().on);
        assert!(!c.is_kill_switch_idle("printer-kill"));
    }

    #[test]
    fn tick_fires_kill_switch_without_plug_state_event() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![Binding {
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
        let mut c = plug_controller(clk.clone(), vec![Binding {
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
            Binding { name: "printer-toggle".into(), trigger: Trigger::Button { device: "hue-ts-office".into(), button: "3".into(), gesture: Gesture::Press }, effect: Effect::Toggle { confirm_off_seconds: None, target: "z2m-p-printer".into() } },
            Binding { name: "printer-kill".into(), trigger: Trigger::PowerBelow { device: "z2m-p-printer".into(), watts: 5.0, for_seconds: 10 }, effect: Effect::TurnOff { target: "z2m-p-printer".into() } },
        ]);
        let _ = c.handle_event(btn_at("hue-ts-office", "3", Gesture::Press, clk.now()));
        assert!(c.plug_state_for("z2m-p-printer").unwrap().on);
        clk.advance(Duration::from_secs(1));
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(100.0), ts: clk.now() });
        clk.advance(Duration::from_secs(1));
        let actions = c.handle_event(btn_at("hue-ts-office", "3", Gesture::Press, clk.now()));
        assert!(actions.iter().any(|a| a.payload == Payload::device_off()));
        assert!(!c.plug_state_for("z2m-p-printer").unwrap().on);
        clk.advance(Duration::from_secs(1));
        let _ = c.handle_event(btn_at("hue-ts-office", "3", Gesture::Press, clk.now()));
        assert!(c.plug_state_for("z2m-p-printer").unwrap().on);
        clk.advance(Duration::from_secs(1));
        let _ = c.handle_event(Event::PlugState { device: "z2m-p-printer".into(), on: true, power: Some(2.0), ts: clk.now() });
        assert!(!c.is_kill_switch_idle("printer-kill"), "stale arming must not survive controller-driven off/on cycle");
    }

    #[test]
    fn kill_switch_trips_after_startup_with_plug_already_below_threshold() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![Binding {
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
        let mut c = plug_controller(clk.clone(), vec![Binding {
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
        let mut c = plug_controller(clk.clone(), vec![Binding {
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
        let mut c = plug_controller(clk.clone(), vec![Binding {
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
    fn unrelated_button_press_does_not_trigger_plug() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = plug_controller(clk.clone(), vec![Binding {
            name: "lamp-on".into(),
            trigger: Trigger::Button { device: "hue-s-office".into(), button: "on".into(), gesture: Gesture::Press },
            effect: Effect::TurnOn { target: "z2m-p-lamp".into() },
        }]);
        // "up" button has no binding → should not trigger plug
        let actions = c.handle_event(btn_at("hue-s-office", "up", Gesture::Press, clk.now()));
        assert!(!actions.iter().any(|a| matches!(a.target, crate::domain::action::ActionTarget::Device(_))));
    }

    // ---- At trigger fires daily -----------------------------------------

    #[test]
    fn at_trigger_fires_again_next_day() {
        let clk = Arc::new(FakeClock::new(22));
        clk.set_minute(59);
        let mut c = plug_controller(clk.clone(), vec![Binding {
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
            switch_models: BTreeMap::new(),
            rooms: vec![
                Room { name: "room-a".into(), group_name: "hue-lz-a".into(), id: 1, members: vec!["hue-l-a/11".into()], parent: None, motion_sensors: vec![], scenes: day_scenes(vec![1]), off_transition_seconds: 0.5, motion_off_cooldown_seconds: 0 },
                Room { name: "room-b".into(), group_name: "hue-lz-b".into(), id: 2, members: vec!["hue-l-b/11".into()], parent: None, motion_sensors: vec![], scenes: day_scenes(vec![1]), off_transition_seconds: 1.0, motion_off_cooldown_seconds: 0 },
            ],
            bindings: vec![Binding { name: "all-off".into(), trigger: Trigger::At { time: fixed_time(23, 0) }, effect: Effect::TurnOffAllZones }],
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

    // ---- binding-only switches in all_switch_device_names ----------------

    #[test]
    fn binding_only_switch_in_all_switch_device_names() {
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([
                ("hue-l-a".into(), light("0xa")),
                ("hue-s-standalone".into(), switch_dev("0x5")),
                ("z2m-p-lamp".into(), plug_dev("0xe", "sonoff-basic", &["on-off"])),
            ]),
            switch_models: test_switch_models(),
            rooms: vec![Room {
                name: "empty-room".into(), group_name: "hue-lz-empty".into(), id: 1,
                members: vec!["hue-l-a/11".into()], parent: None, motion_sensors: vec![],
                scenes: day_scenes(vec![1]), off_transition_seconds: 0.8, motion_off_cooldown_seconds: 0,
            }],
            bindings: vec![Binding {
                name: "lamp-on".into(),
                trigger: Trigger::Button { device: "hue-s-standalone".into(), button: "on".into(), gesture: Gesture::Press },
                effect: Effect::TurnOn { target: "z2m-p-lamp".into() },
            }],
            defaults: Defaults::default(),
            heating: None,
            location: None,
        };
        let topo = Topology::build(&cfg).unwrap();
        assert!(topo.all_switch_device_names().contains("hue-s-standalone"), "binding-only switches must be included in all_switch_device_names");
    }
}
