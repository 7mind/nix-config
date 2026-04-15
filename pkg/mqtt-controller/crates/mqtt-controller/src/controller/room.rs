//! Room-targeting effect executors: scene cycling, turn-off, brightness.
//!
//! These methods implement the room-facing `Effect` variants. Each one
//! resolves the room's group name and scenes via the topology, then
//! produces the appropriate `Action`s.

use std::time::{Duration, Instant};

use crate::domain::action::{Action, Payload};

use super::{Controller, active_slot_scene_ids};

impl Controller {
    /// `SceneCycle` effect — wall switch on-button behavior. Pure scene
    /// cycle: every press advances the cycle unconditionally, no time
    /// component, no toggle-off. The cycle index only resets when the
    /// lights physically go off.
    pub(super) fn execute_scene_cycle(&mut self, room_name: &str, ts: Instant) -> Vec<Action> {
        let sun = self.sun_times();
        let (group_name, scenes_for_now) = {
            let Some(room) = self.topology.room_by_name(room_name) else {
                return Vec::new();
            };
            let hour = self.clock.local_hour();
            let minute = self.clock.local_minute();
            (
                room.group_name.clone(),
                active_slot_scene_ids(&room.scenes, hour, minute, sun.as_ref()),
            )
        };
        if scenes_for_now.is_empty() {
            return Vec::new();
        }
        let n = scenes_for_now.len();

        let state_snapshot = self.states.get(room_name).cloned().unwrap_or_default();
        let (next_idx, branch) = if state_snapshot.physically_on {
            ((state_snapshot.cycle_idx + 1) % n, "cycle advance")
        } else {
            (0, "fresh on (was physically off)")
        };
        let next_scene = scenes_for_now[next_idx];
        tracing::info!(
            room = room_name,
            group = %group_name,
            scene = next_scene,
            cycle_idx_from = state_snapshot.cycle_idx,
            cycle_idx_to = next_idx,
            cycle_len = n,
            branch,
            "scene_cycle → scene_recall"
        );
        let action = Action::new(
            group_name.clone(),
            Payload::scene_recall(next_scene),
        );
        self.write_after_on(room_name, ts, next_idx);
        self.propagate_to_descendants(room_name, true, ts);
        vec![action]
    }

    /// `SceneToggle` effect — pure on/off toggle. If room is off, turn
    /// on with the first scene in the active slot. If room is on, turn
    /// off. No cycle window, no scene advancement. Designed for buttons
    /// that use hardware double-tap for scene cycling.
    pub(super) fn execute_scene_toggle(&mut self, room_name: &str, ts: Instant) -> Vec<Action> {
        let sun = self.sun_times();
        let (group_name, scenes_for_now, off_transition) = {
            let Some(room) = self.topology.room_by_name(room_name) else {
                return Vec::new();
            };
            let hour = self.clock.local_hour();
            let minute = self.clock.local_minute();
            (
                room.group_name.clone(),
                active_slot_scene_ids(&room.scenes, hour, minute, sun.as_ref()),
                room.off_transition_seconds,
            )
        };
        if scenes_for_now.is_empty() {
            return Vec::new();
        }

        let state_snapshot = self.states.get(room_name).cloned().unwrap_or_default();

        if !state_snapshot.physically_on {
            let first = scenes_for_now[0];
            tracing::info!(
                room = room_name,
                group = %group_name,
                scene = first,
                branch = "on (was off)",
                "scene_toggle → scene_recall"
            );
            let action = Action::new(
                group_name.clone(),
                Payload::scene_recall(first),
            );
            self.write_after_on(room_name, ts, 0);
            self.propagate_to_descendants(room_name, true, ts);
            vec![action]
        } else {
            tracing::info!(
                room = room_name,
                group = %group_name,
                transition = off_transition,
                branch = "off (was on)",
                "scene_toggle → state OFF"
            );
            let mut out = Vec::new();
            self.publish_off(room_name, &group_name, off_transition, ts, &mut out);
            out
        }
    }

    /// `SceneToggleCycle` effect — tap button three-branch behavior:
    /// 1. If room is off → turn on with first scene
    /// 2. If within cycle window → advance to next scene
    /// 3. If outside cycle window → turn off
    pub(super) fn execute_scene_toggle_cycle(&mut self, room_name: &str, ts: Instant) -> Vec<Action> {
        let sun = self.sun_times();
        let (group_name, scenes_for_now, off_transition) = {
            let Some(room) = self.topology.room_by_name(room_name) else {
                return Vec::new();
            };
            let hour = self.clock.local_hour();
            let minute = self.clock.local_minute();
            (
                room.group_name.clone(),
                active_slot_scene_ids(&room.scenes, hour, minute, sun.as_ref()),
                room.off_transition_seconds,
            )
        };
        if scenes_for_now.is_empty() {
            return Vec::new();
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
                room = room_name,
                group = %group_name,
                scene = first,
                cycle_idx_to = 0,
                branch = "fresh on (was physically off)",
                "scene_toggle_cycle → scene_recall"
            );
            let action = Action::new(
                group_name.clone(),
                Payload::scene_recall(first),
            );
            self.write_after_on(room_name, ts, 0);
            self.propagate_to_descendants(room_name, true, ts);
            vec![action]
        } else if within_window {
            // Branch 2: cycle to next scene mod N.
            let n = scenes_for_now.len();
            let next_idx = (state_snapshot.cycle_idx + 1) % n;
            let next_scene = scenes_for_now[next_idx];
            let elapsed_ms = elapsed_since_last
                .map(|d| d.as_millis())
                .unwrap_or(0);
            tracing::info!(
                room = room_name,
                group = %group_name,
                scene = next_scene,
                cycle_idx_from = state_snapshot.cycle_idx,
                cycle_idx_to = next_idx,
                cycle_len = n,
                elapsed_ms,
                branch = "cycle advance (within window)",
                "scene_toggle_cycle → scene_recall"
            );
            let action = Action::new(
                group_name.clone(),
                Payload::scene_recall(next_scene),
            );
            self.write_after_on(room_name, ts, next_idx);
            self.propagate_to_descendants(room_name, true, ts);
            vec![action]
        } else {
            // Branch 3: window expired → toggle off.
            let elapsed_ms = elapsed_since_last
                .map(|d| d.as_millis() as i64)
                .unwrap_or(-1);
            tracing::info!(
                room = room_name,
                group = %group_name,
                transition = off_transition,
                elapsed_ms,
                branch = "expire (cycle window passed)",
                "scene_toggle_cycle → state OFF"
            );
            let mut out = Vec::new();
            self.publish_off(room_name, &group_name, off_transition, ts, &mut out);
            out
        }
    }

    /// `TurnOffRoom` effect — turn off a room group with its configured
    /// off transition.
    pub(super) fn execute_turn_off_room(&mut self, room_name: &str, ts: Instant) -> Vec<Action> {
        let Some(room) = self.topology.room_by_name(room_name) else {
            return Vec::new();
        };
        let group_name = room.group_name.clone();
        let off_transition = room.off_transition_seconds;
        tracing::info!(
            room = room_name,
            group = %group_name,
            transition = off_transition,
            "turn_off_room → state OFF"
        );
        let mut out = Vec::new();
        self.publish_off(room_name, &group_name, off_transition, ts, &mut out);
        out
    }

    /// `BrightnessStep` effect — step brightness up or down.
    pub(super) fn execute_brightness_step(&mut self, room_name: &str, step: i16, transition: f64) -> Vec<Action> {
        let Some(room) = self.topology.room_by_name(room_name) else {
            return Vec::new();
        };
        let group_name = room.group_name.clone();
        tracing::info!(
            room = room_name,
            group = %group_name,
            step,
            transition,
            "brightness_step"
        );
        vec![Action::new(group_name, Payload::brightness_step(step, transition))]
    }

    /// `BrightnessMove` effect — start continuous brightness change (hold).
    pub(super) fn execute_brightness_move(&mut self, room_name: &str, rate: i16) -> Vec<Action> {
        let Some(room) = self.topology.room_by_name(room_name) else {
            return Vec::new();
        };
        let group_name = room.group_name.clone();
        tracing::info!(
            room = room_name,
            group = %group_name,
            rate,
            "brightness_move"
        );
        vec![Action::new(group_name, Payload::brightness_move(rate))]
    }

    /// `BrightnessStop` effect — stop continuous brightness change
    /// (hold release). Implemented as brightness_move with rate 0.
    pub(super) fn execute_brightness_stop(&mut self, room_name: &str) -> Vec<Action> {
        let Some(room) = self.topology.room_by_name(room_name) else {
            return Vec::new();
        };
        let group_name = room.group_name.clone();
        tracing::info!(
            room = room_name,
            group = %group_name,
            "brightness_stop"
        );
        vec![Action::new(group_name, Payload::brightness_move(0))]
    }

    pub(super) fn publish_off(
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
        self.propagate_to_descendants(room_name, false, ts);
    }
}
