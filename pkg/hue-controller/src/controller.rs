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
//!
//! ### Cycle button (wall switch `on_press_release`, tap button)
//!
//! Unified semantics across both kinds of cycle button:
//!   1. If `!physically_on` → fresh on. Publish first scene of the
//!      active slot. Reset cycle to 1, mark `last_press_at = now`,
//!      `motion_owned = false`.
//!   2. If `physically_on` AND `now - last_press_at < cycle_window`
//!      → cycle. Publish next scene (`cycle_idx + 1` mod N). Update
//!      `cycle_idx`, `last_press_at`, clear `motion_owned`.
//!   3. If `physically_on` AND `now - last_press_at >= cycle_window`
//!      → expire. Publish state OFF. Reset cycle, clear `motion_owned`,
//!      stamp `last_off_at`.
//!
//! After every transition, we propagate the new physical state to every
//! transitive descendant: descendants get their `physically_on` set, their
//! `last_press_at` cleared (so the next press takes the expire branch),
//! their `cycle_idx` reset.
//!
//! ### Wall switch off button
//!
//! Always immediate OFF, regardless of state. Same propagation as expire.
//!
//! ### Wall switch brightness buttons
//!
//! `up_press_release` → brightness step +N; `down_press_release` → -N.
//! `up_hold` → brightness move +rate; `*_hold_release` → move 0.
//! These don't touch `cycle_idx` or `last_press_at` — they're brightness
//! adjustments, not cycle steps.
//!
//! ### Motion sensor
//!
//! `motion-on` fires iff:
//!   - this sensor reports occupied
//!   - room is `physically_off`
//!   - illuminance gate passes (or no gate)
//!   - cooldown gate passes (`now - last_off_at >= cooldown`)
//!
//! When it fires: publish first scene of slot, mark `motion_owned = true`.
//!
//! `motion-off` fires iff:
//!   - this sensor reports unoccupied
//!   - `motion_owned == true` (we lit the lights, so we own the off)
//!   - all OTHER sensors in the room report inactive
//!   - room is still `physically_on`
//!
//! When it fires: publish state OFF, clear `motion_owned`,
//! stamp `last_off_at`.
//!
//! Every motion event ALSO updates the per-sensor flag in
//! `motion_active_by_sensor` regardless of whether either handler fires.
//!
//! ### External group state
//!
//! When `zigbee2mqtt/<group>` reports a state change, the controller
//! reconciles `physically_on`. If the new state is OFF, also clears
//! `motion_owned` (something else turned the lights off). If the new
//! state is ON and we didn't initiate it, clears `motion_owned` too
//! (the user used HA / the Hue app and we shouldn't motion-off that).
//! `last_press_at` is NOT touched on external state changes — only on
//! actual button presses.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::config::{Defaults, Slot};
use crate::domain::action::{Action, Payload};
use crate::domain::event::{Event, SwitchAction};
use crate::domain::state::ZoneState;
use crate::time::Clock;
use crate::topology::{RoomName, Topology};

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

    /// Per-room state. Initialized lazily on first access — every room
    /// starts at [`ZoneState::default`] and gets its `physically_on`
    /// refreshed by the daemon's startup state-refresh routine before
    /// the first event arrives. Tests can pre-populate via
    /// [`Controller::set_physical_state_for_test`].
    states: BTreeMap<RoomName, ZoneState>,
}

impl Controller {
    pub fn new(topology: Arc<Topology>, clock: Arc<dyn Clock>, defaults: Defaults) -> Self {
        Self {
            topology,
            clock,
            defaults,
            states: BTreeMap::new(),
        }
    }

    /// Single entry point for the daemon's event loop.
    pub fn handle_event(&mut self, event: Event) -> Vec<Action> {
        match event {
            Event::SwitchAction { device, action, ts } => {
                self.handle_switch_action(&device, action, ts)
            }
            Event::TapAction { device, button, ts } => self.handle_tap_action(&device, button, ts),
            Event::Occupancy {
                sensor,
                occupied,
                illuminance,
                ts,
            } => self.handle_occupancy(&sensor, occupied, illuminance, ts),
            Event::GroupState { group, on, ts: _ } => self.handle_group_state(&group, on),
        }
    }

    /// Read-only peek at a room's state. Used by tests and by the
    /// startup state-refresh code path.
    pub fn state_for(&self, room: &str) -> Option<&ZoneState> {
        self.states.get(room)
    }

    /// Set the physical-on flag for a room directly. Used by:
    ///   - the daemon's startup state-refresh routine after it reads the
    ///     retained `zigbee2mqtt/<group>` topic for a room
    ///   - tests that want to set up an initial physical state without
    ///     going through a button press
    pub fn set_physical_state(&mut self, room: &str, on: bool) {
        let state = self.states.entry(room.to_string()).or_default();
        state.physically_on = on;
    }

    /// Walk every room that the startup state refresh observed as
    /// physically on, and mark it as motion-owned.
    ///
    /// Motivation: `motion_owned` doesn't survive a daemon restart (it
    /// only lives in the in-memory `ZoneState` map), so we have no way
    /// to know on cold start whether the lights came on via a user
    /// press, an HA call, or a motion sensor. The conservative default
    /// would be "user-owned" (don't auto-off), but that means lights
    /// that happened to be on at boot stay on indefinitely until the
    /// user explicitly toggles them. The opposite default — assume
    /// motion ownership — costs us at most one false auto-off after
    /// reboot (only if the user genuinely had the lights on for a
    /// non-motion reason), which is far less annoying than lights that
    /// won't go off on their own.
    ///
    /// Called by [`crate::daemon::run`] after the three-phase state
    /// refresh completes, before the event loop starts processing
    /// real-world events.
    pub fn seed_motion_ownership_for_lit_rooms(&mut self) {
        for (room_name, state) in self.states.iter_mut() {
            if state.physically_on && !state.motion_owned {
                tracing::info!(
                    room = %room_name,
                    "startup: seeding motion ownership (room is physically on; \
                     defaulting to motion-owned so motion-off can clear it later)"
                );
                state.motion_owned = true;
            }
        }
    }

    // ----- internal handlers ---------------------------------------------

    fn handle_switch_action(
        &mut self,
        device: &str,
        action: SwitchAction,
        ts: Instant,
    ) -> Vec<Action> {
        let rooms: Vec<RoomName> = self.topology.rooms_for_switch(device).to_vec();
        if rooms.is_empty() {
            return Vec::new();
        }
        let mut out = Vec::new();
        for room_name in &rooms {
            self.dispatch_switch(room_name, device, action, ts, &mut out);
        }
        out
    }

    fn dispatch_switch(
        &mut self,
        room_name: &str,
        device: &str,
        action: SwitchAction,
        ts: Instant,
        out: &mut Vec<Action>,
    ) {
        // Snapshot the immutable bits we need from the topology so the
        // mutable borrow on `self.states` below doesn't fight with the
        // immutable borrow on `self.topology`.
        let Some(room) = self.topology.room_by_name(room_name) else {
            return;
        };
        let group_name = room.group_name.clone();
        let off_transition = room.off_transition_seconds;

        match action {
            SwitchAction::OnPressRelease => {
                self.wall_switch_on_press(room_name, device, ts, out);
            }
            SwitchAction::OffPressRelease => {
                tracing::info!(
                    device,
                    room = room_name,
                    group = %group_name,
                    transition = off_transition,
                    "wall switch off → publish state OFF (dedicated off button)"
                );
                self.publish_off(room_name, &group_name, off_transition, ts, out);
            }
            SwitchAction::UpPressRelease => {
                let step = self.defaults.wall_switch.brightness_step;
                let trans = self.defaults.wall_switch.brightness_step_transition_seconds;
                tracing::info!(
                    device,
                    room = room_name,
                    group = %group_name,
                    step,
                    transition = trans,
                    "wall switch up press → brightness step +"
                );
                out.push(Action::new(group_name, Payload::brightness_step(step, trans)));
            }
            SwitchAction::DownPressRelease => {
                let step = self.defaults.wall_switch.brightness_step;
                let trans = self.defaults.wall_switch.brightness_step_transition_seconds;
                tracing::info!(
                    device,
                    room = room_name,
                    group = %group_name,
                    step = -step,
                    transition = trans,
                    "wall switch down press → brightness step -"
                );
                out.push(Action::new(
                    group_name,
                    Payload::brightness_step(-step, trans),
                ));
            }
            SwitchAction::UpHold => {
                let rate = self.defaults.wall_switch.brightness_move_rate;
                tracing::info!(
                    device,
                    room = room_name,
                    group = %group_name,
                    rate,
                    "wall switch up hold → brightness move + (continuous)"
                );
                out.push(Action::new(group_name, Payload::brightness_move(rate)));
            }
            SwitchAction::DownHold => {
                let rate = self.defaults.wall_switch.brightness_move_rate;
                tracing::info!(
                    device,
                    room = room_name,
                    group = %group_name,
                    rate = -rate,
                    "wall switch down hold → brightness move - (continuous)"
                );
                out.push(Action::new(group_name, Payload::brightness_move(-rate)));
            }
            SwitchAction::UpHoldRelease | SwitchAction::DownHoldRelease => {
                tracing::info!(
                    device,
                    room = room_name,
                    group = %group_name,
                    "wall switch hold release → brightness move stop"
                );
                out.push(Action::new(group_name, Payload::brightness_move(0)));
            }
        }
    }

    fn handle_tap_action(&mut self, device: &str, button: u8, ts: Instant) -> Vec<Action> {
        let rooms: Vec<RoomName> = self
            .topology
            .rooms_for_tap_button(device, button)
            .to_vec();
        if rooms.is_empty() {
            return Vec::new();
        }
        let mut out = Vec::new();
        for room_name in &rooms {
            self.tap_press(room_name, device, button, ts, &mut out);
        }
        out
    }

    /// Wall switch `on_press_release` handler. Pure scene cycle — no
    /// time component, no cycle window. Every press advances by one,
    /// indefinitely. The cycle index only resets when the lights
    /// physically go off (via the dedicated off button or an external
    /// state echo via [`Controller::handle_group_state`]).
    ///
    /// State machine:
    ///   * `!physically_on` → publish first scene of the active slot,
    ///     `cycle_idx = 0`
    ///   * `physically_on`  → publish `scene_ids[(cycle_idx + 1) % N]`,
    ///     `cycle_idx = next_idx`
    fn wall_switch_on_press(
        &mut self,
        room_name: &str,
        device: &str,
        ts: Instant,
        out: &mut Vec<Action>,
    ) {
        let (group_name, scenes_for_now) = {
            let Some(room) = self.topology.room_by_name(room_name) else {
                return;
            };
            let hour = self.clock.local_hour();
            (
                room.group_name.clone(),
                active_slot_scene_ids(&room.scenes, hour),
            )
        };
        if scenes_for_now.is_empty() {
            return;
        }
        let n = scenes_for_now.len();

        let state_snapshot = self.states.get(room_name).cloned().unwrap_or_default();
        let (next_idx, branch) = if state_snapshot.physically_on {
            // Advance the cycle.
            ((state_snapshot.cycle_idx + 1) % n, "cycle advance")
        } else {
            // Off → fresh on at the first scene.
            (0, "fresh on (was physically off)")
        };
        let next_scene = scenes_for_now[next_idx];
        tracing::info!(
            device,
            room = room_name,
            group = %group_name,
            scene = next_scene,
            cycle_idx_from = state_snapshot.cycle_idx,
            cycle_idx_to = next_idx,
            cycle_len = n,
            branch,
            "wall switch on → scene_recall"
        );
        out.push(Action::new(
            group_name.clone(),
            Payload::scene_recall(next_scene),
        ));
        self.write_after_on(room_name, ts, next_idx);
        self.propagate_to_descendants(room_name, true);
    }

    /// Tap button handler. Three-branch state machine — same shape as
    /// the bento `mkTapButtonRule`, just in Rust. The cycle window
    /// (`defaults.cycle_window_seconds`) is the only thing that lets a
    /// tap button distinguish "next scene" from "turn off", so we keep
    /// that logic here.
    ///
    /// State machine:
    ///   1. `!physically_on` → publish first scene of the active slot,
    ///      `cycle_idx = 0`
    ///   2. `physically_on` AND `now - last_press < cycle_window` →
    ///      publish `scene_ids[(cycle_idx + 1) % N]`
    ///   3. `physically_on` AND `now - last_press >= cycle_window` →
    ///      publish state OFF
    fn tap_press(
        &mut self,
        room_name: &str,
        device: &str,
        button: u8,
        ts: Instant,
        out: &mut Vec<Action>,
    ) {
        let (group_name, scenes_for_now, off_transition) = {
            let Some(room) = self.topology.room_by_name(room_name) else {
                return;
            };
            let hour = self.clock.local_hour();
            (
                room.group_name.clone(),
                active_slot_scene_ids(&room.scenes, hour),
                room.off_transition_seconds,
            )
        };
        if scenes_for_now.is_empty() {
            return;
        }
        let cycle_window = Duration::from_secs_f64(self.defaults.cycle_window_seconds);

        let state_snapshot = self.states.get(room_name).cloned().unwrap_or_default();
        let elapsed_since_last = state_snapshot
            .last_press_at
            .map(|last| ts.duration_since(last));
        let within_window = elapsed_since_last.is_some_and(|d| d < cycle_window);

        if !state_snapshot.physically_on {
            // Branch 1: fresh on → first scene.
            let first = scenes_for_now[0];
            tracing::info!(
                device,
                button,
                room = room_name,
                group = %group_name,
                scene = first,
                cycle_idx_to = 0,
                branch = "fresh on (was physically off)",
                "tap press → scene_recall"
            );
            out.push(Action::new(
                group_name.clone(),
                Payload::scene_recall(first),
            ));
            self.write_after_on(room_name, ts, 0);
            self.propagate_to_descendants(room_name, true);
        } else if within_window {
            // Branch 2: cycle to next scene mod N.
            let n = scenes_for_now.len();
            let next_idx = (state_snapshot.cycle_idx + 1) % n;
            let next_scene = scenes_for_now[next_idx];
            let elapsed_ms = elapsed_since_last
                .map(|d| d.as_millis())
                .unwrap_or(0);
            tracing::info!(
                device,
                button,
                room = room_name,
                group = %group_name,
                scene = next_scene,
                cycle_idx_from = state_snapshot.cycle_idx,
                cycle_idx_to = next_idx,
                cycle_len = n,
                elapsed_ms,
                branch = "cycle advance (within window)",
                "tap press → scene_recall"
            );
            out.push(Action::new(
                group_name.clone(),
                Payload::scene_recall(next_scene),
            ));
            self.write_after_on(room_name, ts, next_idx);
            self.propagate_to_descendants(room_name, true);
        } else {
            // Branch 3: window expired → toggle off.
            let elapsed_ms = elapsed_since_last
                .map(|d| d.as_millis() as i64)
                .unwrap_or(-1);
            tracing::info!(
                device,
                button,
                room = room_name,
                group = %group_name,
                transition = off_transition,
                elapsed_ms,
                branch = "expire (cycle window passed)",
                "tap press → state OFF"
            );
            self.publish_off(room_name, &group_name, off_transition, ts, out);
        }
    }

    fn publish_off(
        &mut self,
        room_name: &str,
        group_name: &str,
        off_transition: f64,
        ts: Instant,
        out: &mut Vec<Action>,
    ) {
        out.push(Action::new(
            group_name.to_string(),
            Payload::state_off(off_transition),
        ));
        self.write_after_off(room_name, ts);
        self.propagate_to_descendants(room_name, false);
    }

    fn handle_occupancy(
        &mut self,
        sensor: &str,
        occupied: bool,
        illuminance: Option<u32>,
        ts: Instant,
    ) -> Vec<Action> {
        let rooms: Vec<RoomName> = self.topology.rooms_for_motion(sensor).to_vec();
        if rooms.is_empty() {
            return Vec::new();
        }
        let mut out = Vec::new();
        for room_name in &rooms {
            self.dispatch_motion(room_name, sensor, occupied, illuminance, ts, &mut out);
        }
        out
    }

    fn dispatch_motion(
        &mut self,
        room_name: &str,
        sensor: &str,
        occupied: bool,
        illuminance: Option<u32>,
        ts: Instant,
        out: &mut Vec<Action>,
    ) {
        // Capture room metadata before borrowing mut state.
        let (group_name, max_lux, cooldown_ms, off_transition, scenes_for_now) = {
            let Some(room) = self.topology.room_by_name(room_name) else {
                return;
            };
            let max_lux = room
                .bound_motion
                .iter()
                .find(|m| m.sensor == sensor)
                .and_then(|m| m.max_illuminance);
            let cooldown_ms = room.motion_off_cooldown_seconds * 1000;
            let hour = self.clock.local_hour();
            let scenes = active_slot_scene_ids(&room.scenes, hour);
            (
                room.group_name.clone(),
                max_lux,
                cooldown_ms,
                room.off_transition_seconds,
                scenes,
            )
        };

        // Always update the per-sensor flag, even if the gates below
        // skip the dispatch. This mirrors bento's preDispatch unconditional
        // update — without it, multi-sensor coordination would see stale
        // flags from the sensor that just fired.
        {
            let state = self.states.entry(room_name.to_string()).or_default();
            state.motion_active_by_sensor.insert(sensor.to_string(), occupied);
        }
        let state_snapshot = self.states.get(room_name).cloned().unwrap_or_default();

        if occupied {
            // motion-on gates:
            //   - room currently off
            //   - illuminance < max (or no gate)
            //   - cooldown expired
            if state_snapshot.physically_on {
                tracing::info!(
                    sensor,
                    room = room_name,
                    "motion-on suppressed: lights already physically on"
                );
                return;
            }
            if let (Some(max), Some(actual)) = (max_lux, illuminance)
                && actual >= max
            {
                tracing::info!(
                    sensor,
                    room = room_name,
                    illuminance = actual,
                    max_illuminance = max,
                    "motion-on suppressed: room is bright enough (luminance gate)"
                );
                return;
            }
            if cooldown_ms > 0
                && let Some(last_off) = state_snapshot.last_off_at
                && ts.duration_since(last_off) < Duration::from_millis(cooldown_ms as u64)
            {
                let elapsed_ms = ts.duration_since(last_off).as_millis();
                tracing::info!(
                    sensor,
                    room = room_name,
                    cooldown_ms,
                    elapsed_ms,
                    "motion-on suppressed: cooldown after recent OFF still active"
                );
                return;
            }
            let Some(&first) = scenes_for_now.first() else {
                return;
            };
            tracing::info!(
                sensor,
                room = room_name,
                group = %group_name,
                scene = first,
                illuminance = ?illuminance,
                "motion-on → scene_recall (room was off, gates passed)"
            );
            out.push(Action::new(group_name, Payload::scene_recall(first)));
            // Mark as motion-owned so motion-off can later run.
            let state = self.states.entry(room_name.to_string()).or_default();
            state.physically_on = true;
            state.motion_owned = true;
            state.cycle_idx = 0;
            // Don't touch last_press_at — this isn't a button press.
            self.propagate_to_descendants(room_name, true);
        } else {
            // motion-off gates:
            //   - we own the lights (motion turned them on)
            //   - all other sensors in this room are also inactive
            //   - lights are physically still on
            if !state_snapshot.motion_owned {
                tracing::info!(
                    sensor,
                    room = room_name,
                    "motion-off suppressed: lights are user-owned, not motion-owned"
                );
                return;
            }
            if !state_snapshot.physically_on {
                tracing::info!(
                    sensor,
                    room = room_name,
                    "motion-off suppressed: lights already physically off"
                );
                return;
            }
            if !state_snapshot.all_other_sensors_inactive(sensor) {
                tracing::info!(
                    sensor,
                    room = room_name,
                    "motion-off suppressed: another sensor in this room still reports active"
                );
                return;
            }
            tracing::info!(
                sensor,
                room = room_name,
                group = %group_name,
                transition = off_transition,
                "motion-off → state OFF (motion-owned, all sensors clear)"
            );
            out.push(Action::new(group_name, Payload::state_off(off_transition)));
            let state = self.states.entry(room_name.to_string()).or_default();
            state.physically_on = false;
            state.motion_owned = false;
            state.last_off_at = Some(ts);
            state.cycle_idx = 0;
            self.propagate_to_descendants(room_name, false);
        }
    }

    fn handle_group_state(&mut self, group_name: &str, on: bool) -> Vec<Action> {
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

        // We have a state transition we didn't initiate ourselves
        // (button press handlers set physically_on synchronously, so
        // their own echoes hit the no-transition branch above).
        if on {
            // off → on. We have no way to know whether the user pressed
            // a switch, opened the Hue app, or a motion sensor we don't
            // know about turned the lights on. Default to motion-owned
            // so motion-off can later auto-clear the room. The cost of
            // being wrong is at most one false auto-off; the cost of
            // defaulting the OTHER way is lights stuck on indefinitely
            // until the user manually toggles them. The same reasoning
            // is applied at startup by `seed_motion_ownership_for_lit_rooms`,
            // which still runs as defense in depth for rooms whose
            // group-state event arrived during the refresh window.
            state.motion_owned = true;
            tracing::info!(
                group = group_name,
                room = %room_name,
                from = was_on,
                to = on,
                "group state echo → off→on transition (defaulting to motion-owned)"
            );
        } else {
            // on → off. The lights are gone; reset cycle position so
            // the next on press starts at scene 1. Clear motion
            // ownership too — the room is now off, so motion-off
            // doesn't need ownership to do anything.
            state.motion_owned = false;
            state.cycle_idx = 0;
            tracing::info!(
                group = group_name,
                room = %room_name,
                from = was_on,
                to = on,
                "group state echo → on→off transition (motion ownership cleared)"
            );
        }
        Vec::new()
    }

    // ----- internal helpers ----------------------------------------------

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

    /// Optimistically propagate a parent's new physical state to every
    /// transitive descendant. Mirrors what z2m would tell us via group
    /// state events anyway, but lets the next button press see the
    /// correct state immediately instead of racing the broker round-trip.
    fn propagate_to_descendants(&mut self, ancestor: &str, on: bool) {
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
            // Force the next press of the descendant to take the expire
            // branch (turn off if on, fresh on if off): clear
            // last_press_at so `now - last_press_at` is treated as
            // "infinite". Same idea as the bento `tap_last_press_ms = "0"`
            // we wrote on parent invalidation.
            state.last_press_at = None;
            state.cycle_idx = 0;
            // Descendant is no longer motion-owned: an ancestor press
            // (or motion event) overrides the descendant's previous
            // motion ownership.
            state.motion_owned = false;
            if !on {
                // Mirror what an own-room OFF would do.
                state.last_off_at = None; // reset cooldown for descendants too
            }
        }
    }
}

/// Pull out the `scene_ids` of the slot covering `hour`. Returns an empty
/// slice if no slot matches (which means the schedule is invalid; topology
/// validation rejects that, so this should never happen at runtime — but
/// the controller plays it safe rather than panicking).
fn active_slot_scene_ids(schedule: &crate::config::SceneSchedule, hour: u8) -> Vec<u8> {
    let Some((_name, slot)) = schedule.slot_for_hour(hour) else {
        return Vec::new();
    };
    slot_scene_ids(slot)
}

fn slot_scene_ids(slot: &Slot) -> Vec<u8> {
    slot.scene_ids.clone()
}

#[cfg(test)]
mod tests {
    //! Unit tests for the controller state machine. These run directly
    //! against the controller — no MQTT, no async, sub-millisecond per
    //! test. Each test sets up a small topology, feeds events with a
    //! fake clock, and asserts on the returned actions plus the
    //! resulting zone state.
    //!
    //! Test helpers live in `tests::fixtures`.

    use super::*;
    use crate::config::scenes::{Scene, SceneSchedule, Slot};
    use crate::config::{
        CommonFields, Config, DeviceBinding, DeviceCatalogEntry, Defaults, Room,
    };
    use crate::time::FakeClock;
    use pretty_assertions::assert_eq;

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
                    start_hour: 0,
                    end_hour_exclusive: 24,
                    scene_ids: ids,
                },
            )]),
        }
    }

    fn day_night_scenes() -> SceneSchedule {
        let scenes = vec![
            Scene {
                id: 1,
                name: "bright".into(),
                state: "ON".into(),
                brightness: None,
                color_temp: None,
                transition: 0.0,
            },
            Scene {
                id: 2,
                name: "relaxed".into(),
                state: "ON".into(),
                brightness: None,
                color_temp: None,
                transition: 0.0,
            },
            Scene {
                id: 3,
                name: "dim".into(),
                state: "ON".into(),
                brightness: None,
                color_temp: None,
                transition: 0.0,
            },
        ];
        SceneSchedule {
            scenes,
            slots: BTreeMap::from([
                (
                    "day".into(),
                    Slot {
                        start_hour: 6,
                        end_hour_exclusive: 23,
                        scene_ids: vec![1, 2, 3],
                    },
                ),
                (
                    "night".into(),
                    Slot {
                        start_hour: 23,
                        end_hour_exclusive: 6,
                        scene_ids: vec![3, 2, 1],
                    },
                ),
            ]),
        }
    }

    fn light(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Light(CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::new(),
        })
    }
    fn switch_dev(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Switch(CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::new(),
        })
    }
    fn tap_dev(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Tap(CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::new(),
        })
    }
    fn motion(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::MotionSensor {
            common: CommonFields {
                ieee_address: ieee.into(),
                description: None,
                options: BTreeMap::new(),
            },
            occupancy_timeout_seconds: 60,
            max_illuminance: None,
        }
    }

    fn binding(device: &str, button: Option<u8>) -> DeviceBinding {
        DeviceBinding {
            device: device.into(),
            button,
        }
    }

    /// Build a controller from a tiny "kitchen" topology used by most
    /// tests. Layout:
    ///   - kitchen-cooker (parent: kitchen-all) — tap button 2
    ///   - kitchen-dining (parent: kitchen-all) — tap button 3
    ///   - kitchen-all                          — tap button 1
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
                    name: "kitchen-cooker".into(),
                    group_name: "hue-lz-kitchen-cooker".into(),
                    id: 1,
                    members: vec!["hue-l-cooker/11".into()],
                    parent: Some("kitchen-all".into()),
                    devices: vec![binding("hue-ts-foo", Some(2))],
                    scenes: day_scenes(vec![1, 2, 3]),
                    off_transition_seconds: 0.8,
                    motion_off_cooldown_seconds: 0,
                },
                Room {
                    name: "kitchen-dining".into(),
                    group_name: "hue-lz-kitchen-dining".into(),
                    id: 2,
                    members: vec!["hue-l-dining/11".into()],
                    parent: Some("kitchen-all".into()),
                    devices: vec![binding("hue-ts-foo", Some(3))],
                    scenes: day_scenes(vec![1, 2, 3]),
                    off_transition_seconds: 0.8,
                    motion_off_cooldown_seconds: 0,
                },
                Room {
                    name: "kitchen-all".into(),
                    group_name: "hue-lz-kitchen-all".into(),
                    id: 3,
                    members: vec![
                        "hue-l-cooker/11".into(),
                        "hue-l-dining/11".into(),
                        "hue-l-empty/11".into(),
                    ],
                    parent: None,
                    devices: vec![binding("hue-ts-foo", Some(1))],
                    scenes: day_scenes(vec![1, 2, 3]),
                    off_transition_seconds: 0.8,
                    motion_off_cooldown_seconds: 0,
                },
            ],
            defaults: Defaults::default(),
        };
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        Controller::new(topo, clock, cfg.defaults)
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
                name: "study".into(),
                group_name: "hue-lz-study".into(),
                id: 1,
                members: vec!["hue-l-a/11".into()],
                parent: None,
                devices: vec![
                    binding("hue-s-study", None),
                    binding("hue-ms-study", None),
                ],
                scenes: day_night_scenes(),
                off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 30,
            }],
            defaults: Defaults::default(),
        };
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        Controller::new(topo, clock, cfg.defaults)
    }

    // ---- cycle button: fresh on / cycle / expire ------------------------

    #[test]
    fn tap_press_on_off_zone_publishes_first_scene() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());

        let actions = c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 2,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new(
                "hue-lz-kitchen-cooker",
                Payload::scene_recall(1)
            )]
        );
        let s = c.state_for("kitchen-cooker").unwrap();
        assert!(s.physically_on);
        assert_eq!(s.cycle_idx, 0);
        assert!(s.last_press_at.is_some());
    }

    #[test]
    fn tap_press_within_window_cycles_scene() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());

        c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 2,
            ts: clk.now(),
        });
        clk.advance(Duration::from_millis(200));

        let actions = c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 2,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new(
                "hue-lz-kitchen-cooker",
                Payload::scene_recall(2)
            )]
        );
        assert_eq!(c.state_for("kitchen-cooker").unwrap().cycle_idx, 1);
    }

    #[test]
    fn tap_press_outside_window_expires_to_off() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());

        c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 2,
            ts: clk.now(),
        });
        // Past the 1.0s default cycle window.
        clk.advance(Duration::from_millis(1500));

        let actions = c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 2,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new(
                "hue-lz-kitchen-cooker",
                Payload::state_off(0.8)
            )]
        );
        assert!(!c.state_for("kitchen-cooker").unwrap().physically_on);
    }

    #[test]
    fn tap_cycle_wraps_at_n() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());

        // press 1: scene 1
        c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 2,
            ts: clk.now(),
        });
        clk.advance(Duration::from_millis(100));
        // press 2: scene 2
        c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 2,
            ts: clk.now(),
        });
        clk.advance(Duration::from_millis(100));
        // press 3: scene 3
        c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 2,
            ts: clk.now(),
        });
        clk.advance(Duration::from_millis(100));
        // press 4: wraps to scene 1
        let actions = c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 2,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new(
                "hue-lz-kitchen-cooker",
                Payload::scene_recall(1)
            )]
        );
    }

    // ---- the kitchen-all → kitchen-cooker bug ---------------------------
    //
    // The bento-era regression. After parent-on, child press should
    // toggle the child off — even though the child was lit by the
    // parent.

    #[test]
    fn parent_on_then_child_press_toggles_child_off() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());

        // 1. press button 1 (parent kitchen-all) → fresh on
        let p = c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 1,
            ts: clk.now(),
        });
        assert_eq!(
            p,
            vec![Action::new(
                "hue-lz-kitchen-all",
                Payload::scene_recall(1)
            )]
        );
        // Descendants are now physically_on with last_press_at = None.
        assert!(c.state_for("kitchen-cooker").unwrap().physically_on);
        assert!(c.state_for("kitchen-cooker").unwrap().last_press_at.is_none());

        clk.advance(Duration::from_millis(150));

        // 2. press button 2 (child kitchen-cooker) → expire path → OFF
        let actions = c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 2,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new(
                "hue-lz-kitchen-cooker",
                Payload::state_off(0.8)
            )]
        );
        assert!(!c.state_for("kitchen-cooker").unwrap().physically_on);
    }

    #[test]
    fn parent_on_then_delayed_child_press_still_toggles_off() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());

        c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 1,
            ts: clk.now(),
        });
        clk.advance(Duration::from_millis(2500)); // well past the cycle window

        let actions = c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 2,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new(
                "hue-lz-kitchen-cooker",
                Payload::state_off(0.8)
            )]
        );
    }

    #[test]
    fn parent_on_then_child_off_then_child_on_fresh() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());

        // parent on
        c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 1,
            ts: clk.now(),
        });
        clk.advance(Duration::from_millis(100));
        // child off (the bug-fix path)
        c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 2,
            ts: clk.now(),
        });
        clk.advance(Duration::from_millis(100));
        // child on (fresh — scene 1)
        let actions = c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 2,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new(
                "hue-lz-kitchen-cooker",
                Payload::scene_recall(1)
            )]
        );
    }

    #[test]
    fn child_press_does_not_alter_parent_state() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());

        // child on
        c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 2,
            ts: clk.now(),
        });
        clk.advance(Duration::from_millis(100));
        // parent press → parent's own cache says off → fresh on
        let actions = c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 1,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new(
                "hue-lz-kitchen-all",
                Payload::scene_recall(1)
            )]
        );
    }

    #[test]
    fn parent_cycle_keeps_descendants_marked_on() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());

        c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 1,
            ts: clk.now(),
        });
        clk.advance(Duration::from_millis(200));
        // Cycle the parent.
        c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 1,
            ts: clk.now(),
        });
        clk.advance(Duration::from_millis(200));
        // Child press should still toggle off.
        let actions = c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 2,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new(
                "hue-lz-kitchen-cooker",
                Payload::state_off(0.8)
            )]
        );
    }

    #[test]
    fn sibling_press_independent_of_other_sibling() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = kitchen_controller(clk.clone());

        // cooker on
        c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 2,
            ts: clk.now(),
        });
        clk.advance(Duration::from_millis(100));
        // dining on (independent — its own state was off)
        let actions = c.handle_event(Event::TapAction {
            device: "hue-ts-foo".into(),
            button: 3,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new(
                "hue-lz-kitchen-dining",
                Payload::scene_recall(1)
            )]
        );
    }

    // ---- wall switch on button: cycle / restart-cycle semantics --------
    //
    // Wall switches have a dedicated `off_press_release` button, so the
    // `on_press_release` button is pure "cycle scenes": within the
    // window it advances, outside the window it RESTARTS the cycle from
    // scene 1 (NOT toggles off — that's a tap-only behaviour).

    #[test]
    fn wall_switch_on_press_from_off_publishes_first_scene() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        let actions = c.handle_event(Event::SwitchAction {
            device: "hue-s-study".into(),
            action: SwitchAction::OnPressRelease,
            ts: clk.now(),
        });
        // Day cycle starts at scene 1.
        assert_eq!(
            actions,
            vec![Action::new("hue-lz-study", Payload::scene_recall(1))]
        );
        let s = c.state_for("study").unwrap();
        assert!(s.physically_on);
        assert_eq!(s.cycle_idx, 0);
    }

    #[test]
    fn wall_switch_on_press_within_window_cycles_scene() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        // press 1: scene 1
        c.handle_event(Event::SwitchAction {
            device: "hue-s-study".into(),
            action: SwitchAction::OnPressRelease,
            ts: clk.now(),
        });
        clk.advance(Duration::from_millis(200));
        // press 2 within the window: scene 2
        let actions = c.handle_event(Event::SwitchAction {
            device: "hue-s-study".into(),
            action: SwitchAction::OnPressRelease,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new("hue-lz-study", Payload::scene_recall(2))]
        );
        assert_eq!(c.state_for("study").unwrap().cycle_idx, 1);
    }

    #[test]
    fn wall_switch_on_press_advances_cycle_with_no_time_component() {
        // Wall switches don't have a cycle window — every press just
        // advances by one. This regression test ensures we never
        // accidentally re-introduce a time-based reset on the wall
        // switch path. The user reported this exact bug after the
        // first "unification" attempt.
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        // press 1: scene 1
        let a1 = c.handle_event(Event::SwitchAction {
            device: "hue-s-study".into(),
            action: SwitchAction::OnPressRelease,
            ts: clk.now(),
        });
        assert_eq!(a1, vec![Action::new("hue-lz-study", Payload::scene_recall(1))]);
        // wait FAR past any plausible cycle window
        clk.advance(Duration::from_secs(60));

        // press 2: should still advance to scene 2, NOT restart, NOT toggle off
        let a2 = c.handle_event(Event::SwitchAction {
            device: "hue-s-study".into(),
            action: SwitchAction::OnPressRelease,
            ts: clk.now(),
        });
        assert_eq!(
            a2,
            vec![Action::new("hue-lz-study", Payload::scene_recall(2))],
            "wall switch press should always advance the cycle, regardless of \
             how long ago the previous press was"
        );
        // wait again
        clk.advance(Duration::from_secs(300));

        // press 3: should advance to scene 3
        let a3 = c.handle_event(Event::SwitchAction {
            device: "hue-s-study".into(),
            action: SwitchAction::OnPressRelease,
            ts: clk.now(),
        });
        assert_eq!(a3, vec![Action::new("hue-lz-study", Payload::scene_recall(3))]);

        // press 4: should wrap to scene 1
        clk.advance(Duration::from_secs(10));
        let a4 = c.handle_event(Event::SwitchAction {
            device: "hue-s-study".into(),
            action: SwitchAction::OnPressRelease,
            ts: clk.now(),
        });
        assert_eq!(a4, vec![Action::new("hue-lz-study", Payload::scene_recall(1))]);
    }

    #[test]
    fn wall_switch_off_press_resets_cycle_index() {
        // After the dedicated off button, the next on press should
        // start from scene 1 again — not from wherever the cycle was.
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        // Walk through scenes 1 → 2 → 3.
        for _ in 0..3 {
            c.handle_event(Event::SwitchAction {
                device: "hue-s-study".into(),
                action: SwitchAction::OnPressRelease,
                ts: clk.now(),
            });
            clk.advance(Duration::from_millis(100));
        }
        assert_eq!(c.state_for("study").unwrap().cycle_idx, 2);

        // Off press.
        c.handle_event(Event::SwitchAction {
            device: "hue-s-study".into(),
            action: SwitchAction::OffPressRelease,
            ts: clk.now(),
        });
        assert!(!c.state_for("study").unwrap().physically_on);

        // Next on press → fresh scene 1.
        let actions = c.handle_event(Event::SwitchAction {
            device: "hue-s-study".into(),
            action: SwitchAction::OnPressRelease,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new("hue-lz-study", Payload::scene_recall(1))]
        );
    }

    #[test]
    fn wall_switch_full_cycle_walks_all_scenes_then_wraps() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        // Press 4 times within the window — should walk
        // scene 1 → 2 → 3 → 1 (wraps mod 3).
        let mut emitted: Vec<u8> = Vec::new();
        for _ in 0..4 {
            let actions = c.handle_event(Event::SwitchAction {
                device: "hue-s-study".into(),
                action: SwitchAction::OnPressRelease,
                ts: clk.now(),
            });
            assert_eq!(actions.len(), 1);
            if let Payload::SceneRecall { scene_recall } = actions[0].payload {
                emitted.push(scene_recall);
            } else {
                panic!("expected SceneRecall, got {:?}", actions[0].payload);
            }
            clk.advance(Duration::from_millis(200));
        }
        assert_eq!(emitted, vec![1, 2, 3, 1]);
    }

    // ---- wall switch off button + brightness ----------------------------

    #[test]
    fn wall_switch_off_press_immediately_off() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        // simulate room is on
        c.set_physical_state("study", true);

        let actions = c.handle_event(Event::SwitchAction {
            device: "hue-s-study".into(),
            action: SwitchAction::OffPressRelease,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new("hue-lz-study", Payload::state_off(0.8))]
        );
    }

    #[test]
    fn wall_switch_brightness_up_press_release() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        let actions = c.handle_event(Event::SwitchAction {
            device: "hue-s-study".into(),
            action: SwitchAction::UpPressRelease,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new(
                "hue-lz-study",
                Payload::brightness_step(25, 0.2)
            )]
        );
    }

    #[test]
    fn wall_switch_brightness_down_press_release() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        let actions = c.handle_event(Event::SwitchAction {
            device: "hue-s-study".into(),
            action: SwitchAction::DownPressRelease,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new(
                "hue-lz-study",
                Payload::brightness_step(-25, 0.2)
            )]
        );
    }

    #[test]
    fn wall_switch_hold_and_release_brightness_move() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        let hold = c.handle_event(Event::SwitchAction {
            device: "hue-s-study".into(),
            action: SwitchAction::UpHold,
            ts: clk.now(),
        });
        assert_eq!(
            hold,
            vec![Action::new("hue-lz-study", Payload::brightness_move(40))]
        );

        let release = c.handle_event(Event::SwitchAction {
            device: "hue-s-study".into(),
            action: SwitchAction::UpHoldRelease,
            ts: clk.now(),
        });
        assert_eq!(
            release,
            vec![Action::new("hue-lz-study", Payload::brightness_move(0))]
        );
    }

    // ---- motion sensor --------------------------------------------------

    #[test]
    fn motion_on_in_dark_room_publishes_first_scene() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        let actions = c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(),
            occupied: true,
            illuminance: None,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new("hue-lz-study", Payload::scene_recall(1))]
        );
        let s = c.state_for("study").unwrap();
        assert!(s.physically_on);
        assert!(s.motion_owned);
    }

    #[test]
    fn motion_on_skipped_when_lights_already_on() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        c.set_physical_state("study", true);

        let actions = c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(),
            occupied: true,
            illuminance: None,
            ts: clk.now(),
        });
        assert!(actions.is_empty());
        // We still recorded the sensor as active.
        assert!(c
            .state_for("study")
            .unwrap()
            .motion_active_by_sensor
            .get("hue-ms-study")
            .copied()
            .unwrap_or(false));
    }

    #[test]
    fn motion_off_only_after_owning_motion_on() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        // motion on → owned
        c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(),
            occupied: true,
            illuminance: None,
            ts: clk.now(),
        });
        clk.advance(Duration::from_secs(60));
        // motion off
        let actions = c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(),
            occupied: false,
            illuminance: None,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new("hue-lz-study", Payload::state_off(0.8))]
        );
    }

    #[test]
    fn motion_off_skipped_when_user_owns_lights() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        // user press → motion_owned cleared, lights on
        c.handle_event(Event::SwitchAction {
            device: "hue-s-study".into(),
            action: SwitchAction::OnPressRelease,
            ts: clk.now(),
        });
        // sensor reports motion (no-op, lights already on)
        c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(),
            occupied: true,
            illuminance: None,
            ts: clk.now(),
        });
        clk.advance(Duration::from_secs(60));
        // sensor reports clear
        let actions = c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(),
            occupied: false,
            illuminance: None,
            ts: clk.now(),
        });
        // No off action — user owns the lights.
        assert!(actions.is_empty());
    }

    #[test]
    fn motion_cooldown_blocks_motion_on_after_recent_off() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        // motion on, then motion off (sets last_off_at)
        c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(),
            occupied: true,
            illuminance: None,
            ts: clk.now(),
        });
        clk.advance(Duration::from_secs(60));
        c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(),
            occupied: false,
            illuminance: None,
            ts: clk.now(),
        });
        // Inside cooldown (30s default in fixture).
        clk.advance(Duration::from_secs(5));
        let blocked = c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(),
            occupied: true,
            illuminance: None,
            ts: clk.now(),
        });
        assert!(blocked.is_empty());

        // Past the cooldown.
        clk.advance(Duration::from_secs(30));
        let allowed = c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(),
            occupied: true,
            illuminance: None,
            ts: clk.now(),
        });
        assert_eq!(
            allowed,
            vec![Action::new("hue-lz-study", Payload::scene_recall(1))]
        );
    }

    #[test]
    fn motion_luminance_gate() {
        // Build a controller with the motion sensor's max_illuminance set
        // to 25, so a reading of 30 should suppress motion-on.
        let clk = Arc::new(FakeClock::new(12));
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([
                ("hue-l-a".into(), light("0xa")),
                (
                    "hue-ms-study".into(),
                    DeviceCatalogEntry::MotionSensor {
                        common: CommonFields {
                            ieee_address: "0x2".into(),
                            description: None,
                            options: BTreeMap::new(),
                        },
                        occupancy_timeout_seconds: 60,
                        max_illuminance: Some(25),
                    },
                ),
            ]),
            rooms: vec![Room {
                name: "study".into(),
                group_name: "hue-lz-study".into(),
                id: 1,
                members: vec!["hue-l-a/11".into()],
                parent: None,
                devices: vec![binding("hue-ms-study", None)],
                scenes: day_scenes(vec![1]),
                off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
            }],
            defaults: Defaults::default(),
        };
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        let mut c = Controller::new(topo, clk.clone(), cfg.defaults);

        let bright = c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(),
            occupied: true,
            illuminance: Some(50),
            ts: clk.now(),
        });
        assert!(bright.is_empty());

        let dim = c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(),
            occupied: true,
            illuminance: Some(10),
            ts: clk.now(),
        });
        assert_eq!(
            dim,
            vec![Action::new("hue-lz-study", Payload::scene_recall(1))]
        );
    }

    // ---- multi-sensor coordination --------------------------------------

    #[test]
    fn multi_sensor_motion_off_waits_for_all_inactive() {
        // Two motion sensors in one room. motion-off only fires once
        // both report inactive.
        let clk = Arc::new(FakeClock::new(12));
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([
                ("hue-l-a".into(), light("0xa")),
                ("hue-ms-a".into(), motion("0x1")),
                ("hue-ms-b".into(), motion("0x2")),
            ]),
            rooms: vec![Room {
                name: "hall".into(),
                group_name: "hue-lz-hall".into(),
                id: 1,
                members: vec!["hue-l-a/11".into()],
                parent: None,
                devices: vec![binding("hue-ms-a", None), binding("hue-ms-b", None)],
                scenes: day_scenes(vec![1]),
                off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
            }],
            defaults: Defaults::default(),
        };
        let topo = Arc::new(Topology::build(&cfg).unwrap());
        let mut c = Controller::new(topo, clk.clone(), cfg.defaults);

        // sensor a fires occupied → fresh on, motion_owned=true
        c.handle_event(Event::Occupancy {
            sensor: "hue-ms-a".into(),
            occupied: true,
            illuminance: None,
            ts: clk.now(),
        });
        // sensor b also fires occupied → no-op (lights on, but record flag)
        c.handle_event(Event::Occupancy {
            sensor: "hue-ms-b".into(),
            occupied: true,
            illuminance: None,
            ts: clk.now(),
        });
        // sensor a clears — but b is still active → no off
        let no_off = c.handle_event(Event::Occupancy {
            sensor: "hue-ms-a".into(),
            occupied: false,
            illuminance: None,
            ts: clk.now(),
        });
        assert!(no_off.is_empty());
        // sensor b clears → off fires
        let off = c.handle_event(Event::Occupancy {
            sensor: "hue-ms-b".into(),
            occupied: false,
            illuminance: None,
            ts: clk.now(),
        });
        assert_eq!(
            off,
            vec![Action::new("hue-lz-hall", Payload::state_off(0.8))]
        );
    }

    // ---- startup motion-ownership seed ----------------------------------

    #[test]
    fn seed_motion_ownership_marks_lit_rooms_motion_owned() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        // Pretend the daemon's startup state refresh saw the room
        // physically on (e.g. from a retained group-state message).
        c.set_physical_state("study", true);
        assert!(!c.state_for("study").unwrap().motion_owned);

        c.seed_motion_ownership_for_lit_rooms();

        assert!(
            c.state_for("study").unwrap().motion_owned,
            "lit rooms should default to motion-owned at startup"
        );
    }

    #[test]
    fn seed_motion_ownership_skips_unlit_rooms() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());
        // Room is physically off — motion ownership shouldn't be
        // touched (it's irrelevant; motion-off won't fire on an off room).
        c.set_physical_state("study", false);

        c.seed_motion_ownership_for_lit_rooms();

        assert!(!c.state_for("study").unwrap().motion_owned);
    }

    #[test]
    fn motion_off_fires_after_startup_seed() {
        // Full path: room was physically on at startup → seed motion
        // ownership → next motion-off event auto-clears the room.
        // This is the regression scenario the user reported.
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        // Simulate startup: retained group state showed lights on.
        c.set_physical_state("study", true);
        c.seed_motion_ownership_for_lit_rooms();

        // Sensor stops reporting motion → should publish state OFF
        // (without the seed, this would log "motion-off suppressed:
        // lights are user-owned" and do nothing).
        let actions = c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(),
            occupied: false,
            illuminance: None,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new("hue-lz-study", Payload::state_off(0.8))],
            "seeded motion ownership must let motion-off fire on the first \
             clearance after startup"
        );
    }

    // ---- group state reconciliation -------------------------------------

    #[test]
    fn external_group_off_resets_zone_state() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        // Motion turns lights on (motion-owned).
        c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(),
            occupied: true,
            illuminance: None,
            ts: clk.now(),
        });
        assert!(c.state_for("study").unwrap().motion_owned);

        // Someone uses the Hue app to turn the lights off → group state OFF.
        c.handle_event(Event::GroupState {
            group: "hue-lz-study".into(),
            on: false,
            ts: clk.now(),
        });

        let s = c.state_for("study").unwrap();
        assert!(!s.physically_on);
        assert!(!s.motion_owned);
    }

    #[test]
    fn group_state_same_state_echo_is_a_noop() {
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        // Motion turned the lights on (motion-owned).
        c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(),
            occupied: true,
            illuminance: None,
            ts: clk.now(),
        });
        assert!(c.state_for("study").unwrap().motion_owned);

        // z2m re-publishes the same `state: ON` (could be a periodic
        // update or a retained re-delivery on broker reconnect). No
        // transition → no state changes. Motion ownership preserved.
        c.handle_event(Event::GroupState {
            group: "hue-lz-study".into(),
            on: true,
            ts: clk.now(),
        });
        assert!(c.state_for("study").unwrap().motion_owned);
    }

    #[test]
    fn external_off_to_on_transition_defaults_to_motion_owned() {
        // Off→on transitions we didn't initiate ourselves (HA, the Hue
        // app, manual press at the bulb, /get response after refresh
        // window) default to motion-owned. This way the next motion-off
        // can auto-clear the room. The cost of being wrong is at most
        // one false auto-off; the cost of clearing was lights stuck on
        // until the user manually intervened. The user explicitly
        // requested this default after observing the latter.
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        // Room is currently off.
        assert!(!c.state_for("study").map(|s| s.physically_on).unwrap_or(false));

        // External transition to on (e.g. /get response arrives after
        // the refresh window for a room the seed didn't catch).
        c.handle_event(Event::GroupState {
            group: "hue-lz-study".into(),
            on: true,
            ts: clk.now(),
        });

        let s = c.state_for("study").unwrap();
        assert!(s.physically_on);
        assert!(
            s.motion_owned,
            "external off→on transition must default to motion-owned"
        );
    }

    #[test]
    fn external_on_to_off_transition_clears_motion_ownership() {
        // The inverse direction: external on→off transitions reset
        // ownership (and cycle position). Anyone can have turned the
        // lights off, and motion-off doesn't need ownership of an
        // already-off room.
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        // Motion turned the lights on, then someone uses HA to turn off.
        c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(),
            occupied: true,
            illuminance: None,
            ts: clk.now(),
        });
        c.handle_event(Event::GroupState {
            group: "hue-lz-study".into(),
            on: false,
            ts: clk.now(),
        });

        let s = c.state_for("study").unwrap();
        assert!(!s.physically_on);
        assert!(!s.motion_owned);
        assert_eq!(s.cycle_idx, 0);
    }

    #[test]
    fn motion_off_fires_after_external_on_transition() {
        // Full path of the user's bug report: lights came on via an
        // external trigger (or a slow /get response after restart),
        // then motion goes idle, motion-off should fire instead of
        // suppressing.
        let clk = Arc::new(FakeClock::new(12));
        let mut c = study_with_motion_controller(clk.clone());

        // External on (transition off→on, defaults to motion-owned).
        c.handle_event(Event::GroupState {
            group: "hue-lz-study".into(),
            on: true,
            ts: clk.now(),
        });

        // Motion sensor goes idle.
        let actions = c.handle_event(Event::Occupancy {
            sensor: "hue-ms-study".into(),
            occupied: false,
            illuminance: None,
            ts: clk.now(),
        });
        assert_eq!(
            actions,
            vec![Action::new("hue-lz-study", Payload::state_off(0.8))],
            "motion-off should fire even on rooms whose physically_on \
             came from an external transition"
        );
    }

    // ---- time-of-day slot dispatch --------------------------------------

    #[test]
    fn cycle_uses_active_slot_at_press_time() {
        let clk = Arc::new(FakeClock::new(12)); // day → cycle [1,2,3]
        let mut c = study_with_motion_controller(clk.clone());

        let day_press = c.handle_event(Event::SwitchAction {
            device: "hue-s-study".into(),
            action: SwitchAction::OnPressRelease,
            ts: clk.now(),
        });
        assert_eq!(
            day_press,
            vec![Action::new("hue-lz-study", Payload::scene_recall(1))]
        );

        // Reset back to off.
        c.set_physical_state("study", false);
        let s = c.state_for("study").unwrap().clone();
        assert!(!s.physically_on);

        // Switch to night.
        clk.set_hour(2);
        let night_press = c.handle_event(Event::SwitchAction {
            device: "hue-s-study".into(),
            action: SwitchAction::OnPressRelease,
            ts: clk.now(),
        });
        // Night cycle = [3, 2, 1] → first scene is 3.
        assert_eq!(
            night_press,
            vec![Action::new("hue-lz-study", Payload::scene_recall(3))]
        );
    }
}
