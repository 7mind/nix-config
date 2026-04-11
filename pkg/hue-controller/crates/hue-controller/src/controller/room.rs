//! Room scene-cycling handlers: wall switch and tap button dispatch.

use std::time::{Duration, Instant};

use crate::domain::action::{Action, Payload};
use crate::domain::event::SwitchAction;
use crate::topology::RoomName;

use super::{Controller, active_slot_scene_ids};

impl Controller {
    pub(super) fn handle_switch_action(
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

    pub(super) fn handle_tap_action(
        &mut self,
        device: &str,
        button: u8,
        ts: Instant,
    ) -> Vec<Action> {
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
    /// time component, no cycle window.
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
            ((state_snapshot.cycle_idx + 1) % n, "cycle advance")
        } else {
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
        self.propagate_to_descendants(room_name, true, ts);
    }

    /// Tap button handler. Three-branch state machine.
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
            self.propagate_to_descendants(room_name, true, ts);
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
            self.propagate_to_descendants(room_name, true, ts);
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
