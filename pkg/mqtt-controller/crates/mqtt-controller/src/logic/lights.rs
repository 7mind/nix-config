//! Light zone logic: scene cycling, toggle, brightness, group state echo,
//! and descendant propagation.
//!
//! State access goes through [`WorldState`] / [`LightZoneEntity`] TASS
//! entities with target/actual separation.

use std::time::{Duration, Instant};

use crate::domain::Effect;
use crate::domain::action::Payload;
use crate::entities::light_zone::{LightZoneActual, LightZoneTarget};
use crate::tass::Owner;
use crate::topology::{RoomIdx, RoomName};

use super::EventProcessor;

impl EventProcessor {
    /// `SceneCycle` effect -- wall switch on-button behavior. Pure scene
    /// cycle: every press advances the cycle unconditionally, no time
    /// component, no toggle-off. The cycle index only resets when the
    /// lights physically go off.
    pub(super) fn execute_scene_cycle(&mut self, room_name: &str, ts: Instant) -> Vec<Effect> {
        let scenes_for_now = self.scenes_for_room(room_name);
        let Some(room_idx) = self.topology.room_idx(room_name) else {
            return Vec::new();
        };
        let room = self.topology.room(room_idx);
        let group_name = room.group_name.clone();

        if scenes_for_now.is_empty() {
            return Vec::new();
        }
        let n = scenes_for_now.len();

        let zone = self.world.light_zone(room_name);
        let (next_idx, branch) = if zone.is_on() {
            ((zone.cycle_idx() + 1) % n, "cycle advance")
        } else {
            (0, "fresh on (was physically off)")
        };
        let prev_idx = zone.cycle_idx();
        let next_scene = scenes_for_now[next_idx];
        tracing::info!(
            room = room_name,
            group = %group_name,
            scene = next_scene,
            cycle_idx_from = prev_idx,
            cycle_idx_to = next_idx,
            cycle_len = n,
            branch,
            "scene_cycle → scene_recall"
        );
        let effect = Effect::PublishGroupSet {
            room: room_idx,
            payload: Payload::scene_recall(next_scene),
        };
        self.write_after_on(room_name, ts, next_idx, next_scene, Owner::User);
        self.propagate_to_descendants(room_name, true, ts);
        vec![effect]
    }

    /// `SceneToggle` effect -- pure on/off toggle. If room is off, turn
    /// on with the first scene in the active slot. If room is on, turn
    /// off. No cycle window, no scene advancement. Designed for buttons
    /// that use hardware double-tap for scene cycling.
    pub(super) fn execute_scene_toggle(&mut self, room_name: &str, ts: Instant) -> Vec<Effect> {
        let scenes_for_now = self.scenes_for_room(room_name);
        let Some(room_idx) = self.topology.room_idx(room_name) else {
            return Vec::new();
        };
        let room = self.topology.room(room_idx);
        let group_name = room.group_name.clone();
        let off_transition = room.off_transition_seconds;

        if scenes_for_now.is_empty() {
            return Vec::new();
        }

        let zone = self.world.light_zone(room_name);
        let is_on = zone.is_on();

        if !is_on {
            let first = scenes_for_now[0];
            tracing::info!(
                room = room_name,
                group = %group_name,
                scene = first,
                branch = "on (was off)",
                "scene_toggle → scene_recall"
            );
            let effect = Effect::PublishGroupSet {
                room: room_idx,
                payload: Payload::scene_recall(first),
            };
            self.write_after_on(room_name, ts, 0, first, Owner::User);
            self.propagate_to_descendants(room_name, true, ts);
            vec![effect]
        } else {
            tracing::info!(
                room = room_name,
                group = %group_name,
                transition = off_transition,
                branch = "off (was on)",
                "scene_toggle → state OFF"
            );
            let mut out = Vec::new();
            self.publish_off(room_name, room_idx, off_transition, ts, &mut out, Owner::User);
            out
        }
    }

    /// `SceneToggleCycle` effect -- tap button three-branch behavior:
    /// 1. If room is off -> turn on with first scene
    /// 2. If within cycle window -> advance to next scene
    /// 3. If outside cycle window -> turn off
    pub(super) fn execute_scene_toggle_cycle(&mut self, room_name: &str, ts: Instant) -> Vec<Effect> {
        let scenes_for_now = self.scenes_for_room(room_name);
        let Some(room_idx) = self.topology.room_idx(room_name) else {
            return Vec::new();
        };
        let room = self.topology.room(room_idx);
        let group_name = room.group_name.clone();
        let off_transition = room.off_transition_seconds;

        if scenes_for_now.is_empty() {
            return Vec::new();
        }
        let cycle_window = Duration::from_secs_f64(self.defaults.cycle_window_seconds);

        let zone = self.world.light_zone(room_name);
        let is_on = zone.is_on();
        let prev_idx = zone.cycle_idx();
        let elapsed_since_last = zone.last_press_at.map(|last| ts.duration_since(last));
        let within_window = elapsed_since_last.is_some_and(|d| d < cycle_window);

        if !is_on {
            // Branch 1: fresh on -> first scene.
            let first = scenes_for_now[0];
            tracing::info!(
                room = room_name,
                group = %group_name,
                scene = first,
                cycle_idx_to = 0,
                branch = "fresh on (was physically off)",
                "scene_toggle_cycle → scene_recall"
            );
            let effect = Effect::PublishGroupSet {
                room: room_idx,
                payload: Payload::scene_recall(first),
            };
            self.write_after_on(room_name, ts, 0, first, Owner::User);
            self.propagate_to_descendants(room_name, true, ts);
            vec![effect]
        } else if within_window {
            // Branch 2: cycle to next scene mod N.
            let n = scenes_for_now.len();
            let next_idx = (prev_idx + 1) % n;
            let next_scene = scenes_for_now[next_idx];
            let elapsed_ms = elapsed_since_last
                .map(|d| d.as_millis())
                .unwrap_or(0);
            tracing::info!(
                room = room_name,
                group = %group_name,
                scene = next_scene,
                cycle_idx_from = prev_idx,
                cycle_idx_to = next_idx,
                cycle_len = n,
                elapsed_ms,
                branch = "cycle advance (within window)",
                "scene_toggle_cycle → scene_recall"
            );
            let effect = Effect::PublishGroupSet {
                room: room_idx,
                payload: Payload::scene_recall(next_scene),
            };
            self.write_after_on(room_name, ts, next_idx, next_scene, Owner::User);
            self.propagate_to_descendants(room_name, true, ts);
            vec![effect]
        } else {
            // Branch 3: window expired -> toggle off.
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
            self.publish_off(room_name, room_idx, off_transition, ts, &mut out, Owner::User);
            out
        }
    }

    /// `TurnOffRoom` effect -- turn off a room group with its configured
    /// off transition.
    pub(super) fn execute_turn_off_room(&mut self, room_name: &str, ts: Instant) -> Vec<Effect> {
        let Some(room_idx) = self.topology.room_idx(room_name) else {
            return Vec::new();
        };
        let room = self.topology.room(room_idx);
        let group_name = room.group_name.clone();
        let off_transition = room.off_transition_seconds;
        tracing::info!(
            room = room_name,
            group = %group_name,
            transition = off_transition,
            "turn_off_room → state OFF"
        );
        let mut out = Vec::new();
        self.publish_off(room_name, room_idx, off_transition, ts, &mut out, Owner::User);
        out
    }

    /// `BrightnessStep` effect -- step brightness up or down.
    pub(super) fn execute_brightness_step(&mut self, room_name: &str, step: i16, transition: f64) -> Vec<Effect> {
        let Some(room_idx) = self.topology.room_idx(room_name) else {
            return Vec::new();
        };
        let room = self.topology.room(room_idx);
        let group_name = room.group_name.clone();
        tracing::info!(
            room = room_name,
            group = %group_name,
            step,
            transition,
            "brightness_step"
        );
        vec![Effect::PublishGroupSet {
            room: room_idx,
            payload: Payload::brightness_step(step, transition),
        }]
    }

    /// `BrightnessMove` effect -- start continuous brightness change (hold).
    pub(super) fn execute_brightness_move(&mut self, room_name: &str, rate: i16) -> Vec<Effect> {
        let Some(room_idx) = self.topology.room_idx(room_name) else {
            return Vec::new();
        };
        let room = self.topology.room(room_idx);
        let group_name = room.group_name.clone();
        tracing::info!(
            room = room_name,
            group = %group_name,
            rate,
            "brightness_move"
        );
        vec![Effect::PublishGroupSet {
            room: room_idx,
            payload: Payload::brightness_move(rate),
        }]
    }

    /// `BrightnessStop` effect -- stop continuous brightness change
    /// (hold release). Implemented as brightness_move with rate 0.
    pub(super) fn execute_brightness_stop(&mut self, room_name: &str) -> Vec<Effect> {
        let Some(room_idx) = self.topology.room_idx(room_name) else {
            return Vec::new();
        };
        let room = self.topology.room(room_idx);
        let group_name = room.group_name.clone();
        tracing::info!(
            room = room_name,
            group = %group_name,
            "brightness_stop"
        );
        vec![Effect::PublishGroupSet {
            room: room_idx,
            payload: Payload::brightness_move(0),
        }]
    }

    // ----- shared helpers ---------------------------------------------------

    pub(super) fn publish_off(
        &mut self,
        room_name: &str,
        room_idx: RoomIdx,
        off_transition: f64,
        ts: Instant,
        out: &mut Vec<Effect>,
        owner: Owner,
    ) {
        out.push(Effect::PublishGroupSet {
            room: room_idx,
            payload: Payload::state_off(off_transition),
        });
        self.write_after_off(room_name, ts, owner);
        self.propagate_to_descendants(room_name, false, ts);
    }

    /// TASS write-after-on: set target to On with the given owner,
    /// update last_press_at.
    fn write_after_on(&mut self, room_name: &str, ts: Instant, cycle_idx: usize, scene_id: u8, owner: Owner) {
        let zone = self.world.light_zone(room_name);
        zone.target.set_and_command(
            LightZoneTarget::On { scene_id, cycle_idx },
            owner,
            ts,
        );
        zone.last_press_at = Some(ts);
    }

    /// TASS write-after-off: set target to Off with the given owner,
    /// update timestamps.
    fn write_after_off(&mut self, room_name: &str, ts: Instant, owner: Owner) {
        let zone = self.world.light_zone(room_name);
        zone.target.set_and_command(LightZoneTarget::Off, owner, ts);
        zone.last_press_at = Some(ts);
        zone.last_off_at = Some(ts);
    }

    /// Process z2m group state echo. Updates the light zone's actual
    /// state. On off-transitions, clears motion ownership and resets
    /// cycle state. Uses soft propagation to descendants (preserves
    /// cycle state in children).
    pub(super) fn handle_group_state(
        &mut self,
        group_name: &str,
        on: bool,
        ts: Instant,
    ) -> Vec<Effect> {
        let Some(room) = self.topology.room_by_group_name(group_name) else {
            return Vec::new();
        };
        let room_name = room.name.clone();

        let zone = self.world.light_zone(&room_name);
        let new_actual = if on { LightZoneActual::On } else { LightZoneActual::Off };
        // Use is_on() (target OR actual) not actual_is_on() — the target
        // may say On optimistically even before the first actual echo arrives.
        let was_on = zone.is_on();
        zone.actual.update(new_actual, ts);

        // If actual now matches target and target is Commanded, advance
        // to Confirmed. Only for ON echoes — OFF transitions overwrite
        // the target below (making a confirm here redundant).
        if on && matches!(zone.target.phase(), crate::tass::TargetPhase::Commanded | crate::tass::TargetPhase::Stale) {
            if let Some(LightZoneTarget::On { .. }) = zone.target.value() {
                zone.target.confirm(ts);
            }
        }

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
            // Off transition: reset zone to clean state.
            let zone = self.world.light_zone(&room_name);
            zone.target.set_and_command(LightZoneTarget::Off, Owner::System, ts);
            zone.target.confirm(ts);
            zone.last_off_at = Some(ts);
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
        // cycle_idx) -- a group echo is NOT an explicit button press,
        // so it must not destroy a child's in-progress scene cycle.
        self.soft_propagate_to_descendants(&room_name, on, ts);

        Vec::new()
    }

    /// Optimistically propagate a parent's new physical state to every
    /// transitive descendant. Resets cycle state and motion ownership.
    pub(super) fn propagate_to_descendants(&mut self, ancestor: &str, on: bool, ts: Instant) {
        let Some(ancestor_idx) = self.topology.room_idx(ancestor) else {
            return;
        };
        let descendant_idxs: Vec<RoomIdx> =
            self.topology.descendants_of(ancestor_idx).to_vec();
        if descendant_idxs.is_empty() {
            return;
        }
        let descendants: Vec<RoomName> = descendant_idxs
            .iter()
            .map(|&idx| self.topology.room(idx).name.clone())
            .collect();
        tracing::info!(
            ancestor,
            descendants = ?descendants,
            physically_on = on,
            "propagating physical state to descendants (next press takes \
             toggle-off branch instead of fresh-on)"
        );
        for desc in descendants {
            let zone = self.world.light_zone(&desc);
            if on {
                // Propagate on: set target to System-owned On (clears any
                // stale motion ownership or cycle state from a prior session)
                // and update actual. scene_id 0 is a placeholder — the
                // parent's scene_recall command drove the bulbs.
                zone.target.set_and_command(
                    LightZoneTarget::On { scene_id: 0, cycle_idx: 0 },
                    Owner::System,
                    ts,
                );
                zone.actual.update(LightZoneActual::On, ts);
            } else {
                zone.target.set_and_command(LightZoneTarget::Off, Owner::System, ts);
                zone.actual.update(LightZoneActual::Off, ts);
                zone.last_off_at = Some(ts);
            }
            zone.last_press_at = None;
        }
    }

    /// Soft propagation: update only actual state (and last_off_at on off
    /// transitions) for descendants. Does NOT reset last_press_at or
    /// cycle_idx.
    ///
    /// Used by `handle_group_state` where the echo is a side-effect of
    /// z2m aggregating member states, not an explicit user action. If
    /// we cleared cycle state here, a child room's tap-press cycle
    /// window would be destroyed every time z2m re-publishes the
    /// parent group's state after the child turned on.
    fn soft_propagate_to_descendants(&mut self, ancestor: &str, on: bool, ts: Instant) {
        let Some(ancestor_idx) = self.topology.room_idx(ancestor) else {
            return;
        };
        let descendant_idxs: Vec<RoomIdx> =
            self.topology.descendants_of(ancestor_idx).to_vec();
        if descendant_idxs.is_empty() {
            return;
        }
        let descendants: Vec<RoomName> = descendant_idxs
            .iter()
            .map(|&idx| self.topology.room(idx).name.clone())
            .collect();
        tracing::debug!(
            ancestor,
            descendants = ?descendants,
            physically_on = on,
            "group echo: soft-propagating physical state to descendants \
             (preserving cycle state)"
        );
        for desc in descendants {
            let zone = self.world.light_zone(&desc);
            let new_actual = if on { LightZoneActual::On } else { LightZoneActual::Off };
            zone.actual.update(new_actual, ts);
            if !on {
                // Clear descendant target on OFF echo — prevents stale
                // target=On from making is_on() return true after the
                // parent group physically went off.
                zone.target.set_and_command(LightZoneTarget::Off, Owner::System, ts);
                zone.last_off_at = Some(ts);
            }
        }
    }

    /// Record per-light state as published by z2m. Read-only update; no
    /// commands, no propagation. The group-level [`LightZoneEntity`] is
    /// unaffected — it receives its own update via [`Event::GroupState`].
    pub(super) fn handle_light_state(
        &mut self,
        device: &str,
        on: bool,
        brightness: Option<u8>,
        color_temp: Option<u16>,
        color_xy: Option<(f64, f64)>,
        ts: Instant,
    ) {
        let light = self.world.light(device);
        light.actual.update(
            crate::entities::light::LightActual {
                on,
                brightness,
                color_temp,
                color_xy,
            },
            ts,
        );
    }
}
