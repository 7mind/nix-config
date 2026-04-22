//! Motion-sensor dispatch: occupancy gating, multi-sensor OR-gate,
//! illuminance gate, cooldown gate.
//!
//! Per-sensor occupancy is tracked in [`MotionSensorEntity`] actual
//! state (freshness-aware). Motion
//! ownership is tracked via [`LightZoneEntity::is_motion_owned()`]
//! (target owner == Motion).
//!
//! The room's [`MotionMode`] controls which branches fire:
//!   * `OnOff`    — both branches (historical default).
//!   * `OnOnly`   — motion-on turns lights on without claiming motion
//!                  ownership (Owner::User), motion-off is a no-op.
//!   * `OffOnly`  — motion-on claims motion ownership without turning
//!                  lights on; motion-off turns lights off if they are
//!                  physically on. User/web presses preserve the motion
//!                  claim (see `resolve_zone_owner` in `lights.rs`), so
//!                  the user cannot revoke the scheduled off.

use std::time::{Duration, Instant};

use crate::config::room::MotionMode;
use crate::domain::Effect;
use crate::domain::action::Payload;
use crate::entities::light_zone::LightZoneTarget;
use crate::entities::motion_sensor::MotionActual;
use crate::tass::{ActualFreshness, Owner, TargetPhase};
use crate::topology::{RoomIdx, RoomName};

use super::EventProcessor;

impl EventProcessor {
    pub(super) fn handle_occupancy(
        &mut self,
        sensor: &str,
        occupied: bool,
        illuminance: Option<u32>,
        ts: Instant,
    ) -> Vec<Effect> {
        let room_idxs: Vec<RoomIdx> =
            self.topology.rooms_for_motion(sensor).to_vec();
        if room_idxs.is_empty() {
            return Vec::new();
        }
        let rooms: Vec<(RoomIdx, RoomName)> = room_idxs
            .iter()
            .map(|&idx| (idx, self.topology.room(idx).name.clone()))
            .collect();

        // Capture this sensor's prior state ONCE, before any
        // dispatch_motion iteration touches its actual. For sensors
        // bound to multiple rooms, dispatch_motion updates the actual
        // on the first iteration, so a per-iteration re-read would
        // see the post-update state in every room after the first
        // — breaking both the repeated-false dedup and the new-session
        // detection. Threading both flags down keeps per-room
        // decisions consistent.
        let prev_occupied = self
            .world
            .motion_sensors
            .get(sensor)
            .and_then(|s| s.actual.value())
            .map(|a| a.occupied);
        let prev_sensor_was_occupied = self
            .world
            .motion_sensors
            .get(sensor)
            .is_some_and(|s| s.is_occupied());

        let mut out = Vec::new();
        for (room_idx, room_name) in &rooms {
            self.dispatch_motion(
                *room_idx,
                room_name,
                sensor,
                occupied,
                illuminance,
                ts,
                prev_occupied,
                prev_sensor_was_occupied,
                &mut out,
            );
        }
        out
    }

    #[allow(clippy::too_many_arguments)]
    fn dispatch_motion(
        &mut self,
        room_idx: RoomIdx,
        room_name: &str,
        sensor: &str,
        occupied: bool,
        illuminance: Option<u32>,
        ts: Instant,
        prev_occupied: Option<bool>,
        prev_sensor_was_occupied: bool,
        out: &mut Vec<Effect>,
    ) {
        // Capture room metadata before borrowing mut state.
        let sun = self.sun_times();
        let (group_name, max_lux, cooldown_ms, off_transition, scenes_for_now, motion_mode) = {
            let Some(room) = self.topology.room_by_name(room_name) else {
                return;
            };
            // Use the highest max_illuminance across all motion sensors
            // in the room. When multiple sensors have different thresholds,
            // the most permissive one wins -- if any sensor considers the
            // room dark enough, motion-on should fire.
            let max_lux = room
                .bound_motion
                .iter()
                .filter_map(|m| m.max_illuminance)
                .max();
            let cooldown_ms = room.motion_off_cooldown_seconds * 1000;
            let hour = self.clock.local_hour();
            let minute = self.clock.local_minute();
            let scenes = room.scenes.active_slot_scene_ids(hour, minute, sun.as_ref());
            (
                room.group_name.clone(),
                max_lux,
                cooldown_ms,
                room.off_transition_seconds,
                scenes,
                room.motion_mode,
            )
        };

        // Dedup for repeated false uses the `prev_occupied` captured in
        // `handle_occupancy` BEFORE any per-room iteration mutated the
        // sensor state — otherwise a sensor bound to multiple rooms
        // would dedup every room after the first.

        // Snapshot "is the room currently inside an occupancy session"
        // BEFORE any actual update lands. For a new `occupied=true`
        // we use this to decide whether to release a zombie Motion
        // claim when the lux/cooldown gate suppresses this event — a
        // suppressed claim must not be backdoored by an older claim
        // from a past session. We check all bound sensors: this one's
        // prior state is threaded in via `prev_sensor_was_occupied`
        // (so multi-room sensors see consistent history), others use
        // their current `is_occupied()` since they haven't been touched
        // by this event.
        let room_was_occupied_before = self
            .topology
            .room_by_name(room_name)
            .is_some_and(|room| {
                room.bound_motion.iter().any(|bm| {
                    if bm.sensor == sensor {
                        prev_sensor_was_occupied
                    } else {
                        self.world
                            .motion_sensors
                            .get(&bm.sensor)
                            .is_some_and(|s| s.is_occupied())
                    }
                })
            });

        // Always update the motion sensor entity's actual state, even if
        // the gates below skip the dispatch. This mirrors bento's
        // preDispatch unconditional update -- without it, multi-sensor
        // coordination would see stale flags from the sensor that just
        // fired.
        self.world
            .motion_sensor(sensor)
            .actual
            .update(MotionActual { occupied, illuminance }, ts);

        if !occupied && prev_occupied == Some(false) {
            return;
        }

        // Symmetric dedup for `occupied=true`. Hue sensors latch
        // occupancy for `occupancyTimeoutSeconds` (180 s in our
        // catalog) and re-publish their state on every illuminance
        // heartbeat (~10 s). Each republish arrives with the same
        // occupancy value as the previous one — no false→true edge.
        //
        // Without this, a republish after a manual OFF (or any event
        // that drops the room's illuminance back below the luminance
        // gate) lets motion-on re-fire scene_recall, so the user
        // presses OFF and the next heartbeat (~10 s later) turns the
        // lights straight back on. See ms-log-full.txt at 00:49:57 →
        // 00:50:07 and 00:50:34 → 00:50:37 for two live instances.
        //
        // Freshness-aware: we dedup only when the sensor's prior
        // reading was `Fresh + occupied` (i.e. `prev_sensor_was_occupied`).
        // A sensor that dropped off the network and aged to Stale loses
        // that flag, so a subsequent `occupied=true` crosses the
        // Stale→Fresh boundary and is correctly treated as a new
        // session (handled by `release_zombie_off_only_claim_if_gate_suppressed`
        // and the ownership-healing path below). Using the raw
        // `prev_occupied` value here would silently suppress that new
        // session.
        //
        // The sensor's `actual` was already updated above so
        // multi-sensor OR-gates and the stale-sweep timer still see
        // the fresh reading; only the dispatch side effects (scene
        // recall, ownership writes, descendant propagation) are
        // skipped. Button-press handling, group-state echoes, and the
        // Hue sensor's eventual `occupied=false` publish all remain
        // capable of changing state.
        if occupied && prev_sensor_was_occupied {
            return;
        }

        if occupied {
            self.dispatch_motion_on(
                room_idx,
                room_name,
                sensor,
                illuminance,
                ts,
                motion_mode,
                max_lux,
                cooldown_ms,
                &group_name,
                &scenes_for_now,
                !room_was_occupied_before,
                out,
            );
        } else {
            self.dispatch_motion_off(
                room_idx,
                room_name,
                sensor,
                ts,
                motion_mode,
                off_transition,
                &group_name,
                out,
            );
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn dispatch_motion_on(
        &mut self,
        room_idx: RoomIdx,
        room_name: &str,
        sensor: &str,
        illuminance: Option<u32>,
        ts: Instant,
        motion_mode: MotionMode,
        max_lux: Option<u32>,
        cooldown_ms: u32,
        group_name: &str,
        scenes_for_now: &[u8],
        is_new_session_event: bool,
        out: &mut Vec<Effect>,
    ) {
        // Common suppressors that apply to every mode that DOES something
        // on motion-on. on-off and on-only suppress the light-up command;
        // off-only suppresses the ownership claim so a bright room or the
        // after-off cooldown window cannot silently arm a later auto-off.
        if let (Some(max), Some(actual)) = (max_lux, illuminance)
            && actual >= max
        {
            tracing::info!(
                sensor,
                room = room_name,
                illuminance = actual,
                max_illuminance = max,
                mode = ?motion_mode,
                "motion-on suppressed: room is bright enough (luminance gate)"
            );
            self.release_zombie_off_only_claim_if_gate_suppressed(
                motion_mode,
                is_new_session_event,
                room_name,
                sensor,
                "lux",
                ts,
            );
            return;
        }
        let last_off = self.world.light_zone(room_name).last_motion_off_at;
        if cooldown_ms > 0
            && let Some(last_off) = last_off
            && ts.duration_since(last_off) < Duration::from_millis(cooldown_ms as u64)
        {
            let elapsed_ms = ts.duration_since(last_off).as_millis();
            tracing::info!(
                sensor,
                room = room_name,
                cooldown_ms,
                elapsed_ms,
                mode = ?motion_mode,
                "motion-on suppressed: cooldown after recent OFF still active"
            );
            self.release_zombie_off_only_claim_if_gate_suppressed(
                motion_mode,
                is_new_session_event,
                room_name,
                sensor,
                "cooldown",
                ts,
            );
            return;
        }

        // off-only: don't publish anything, just claim motion ownership
        // so the later motion-off is authorised. User presses in this
        // room preserve the claim (see `resolve_zone_owner`).
        //
        // Target healing: we adopt a target matching the observed actual
        // state when the target is either:
        //   * Unset (first claim on a fresh zone), or
        //   * Stale AND divergent from actual — a prior command
        //     timed out without an echo and is definitely no longer
        //     in-flight. Without healing here, an abandoned `On/Stale`
        //     target would keep `is_on()` true while lights are
        //     physically off, and the next SceneToggle press would
        //     take the OFF branch.
        //
        // We deliberately do NOT heal `Commanded` targets — those are
        // in-flight user presses and racing with their echo would drop
        // legitimate commands. Their Motion takeover is just an owner
        // handover; the pending command and its scene/cycle data stay.
        if motion_mode == MotionMode::OffOnly {
            let zone = self.world.light_zone(room_name);
            let actual_on = zone.actual_is_on();
            let target_on = zone.target_is_on();
            let target_unset = zone.target.is_unset();
            let target_phase = zone.target.phase();
            let stale_divergent =
                target_phase == TargetPhase::Stale && target_on != actual_on;
            if target_unset || stale_divergent {
                let healed = if actual_on {
                    LightZoneTarget::On { scene_id: 0, cycle_idx: 0 }
                } else {
                    LightZoneTarget::Off
                };
                if !target_unset {
                    tracing::warn!(
                        sensor,
                        room = room_name,
                        target_on,
                        actual_on,
                        "off-only claim: stale target diverged from actual — healing to match observed state"
                    );
                }
                zone.target.adopt(healed, Owner::Motion, ts);
            } else if zone.target.owner() != Some(Owner::Motion) {
                // Idempotent handover: skip the reassign when ownership
                // is already Motion so repeat `occupied=true` publishes
                // during an active session don't thrash `since`.
                zone.target.reassign_owner(Owner::Motion, ts);
            }
            tracing::info!(
                sensor,
                room = room_name,
                group = %group_name,
                "motion-on (off-only) → claim motion ownership, no scene recall"
            );
            return;
        }

        // on-off / on-only: lights-already-on short-circuits scene_recall.
        let zone = self.world.light_zone(room_name);
        if zone.is_on() {
            tracing::info!(
                sensor,
                room = room_name,
                "motion-on suppressed: lights already physically on"
            );
            return;
        }
        let Some(&first) = scenes_for_now.first() else {
            return;
        };
        // on-only skips motion ownership so subsequent user presses are
        // plain user-owned; on-off claims motion ownership so motion-off
        // is authorised to run later.
        let owner = match motion_mode {
            MotionMode::OnOff => Owner::Motion,
            MotionMode::OnOnly => Owner::User,
            MotionMode::OffOnly => unreachable!("off-only handled above"),
        };
        tracing::info!(
            sensor,
            room = room_name,
            group = %group_name,
            scene = first,
            illuminance = ?illuminance,
            mode = ?motion_mode,
            ?owner,
            "motion-on → scene_recall (room was off, gates passed)"
        );
        out.push(Effect::PublishGroupSet {
            room: room_idx,
            payload: Payload::scene_recall(first),
        });
        let zone = self.world.light_zone(room_name);
        zone.target.set_and_command(
            LightZoneTarget::On { scene_id: first, cycle_idx: 0 },
            owner,
            ts,
        );
        // Don't touch last_press_at -- this isn't a button press.
        self.propagate_to_descendants(room_name, true, ts);
    }

    #[allow(clippy::too_many_arguments)]
    fn dispatch_motion_off(
        &mut self,
        room_idx: RoomIdx,
        room_name: &str,
        sensor: &str,
        ts: Instant,
        motion_mode: MotionMode,
        off_transition: f64,
        group_name: &str,
        out: &mut Vec<Effect>,
    ) {
        // on-only: motion never drives off-transitions.
        if motion_mode == MotionMode::OnOnly {
            tracing::debug!(
                sensor,
                room = room_name,
                "motion-off skipped: room is on-only"
            );
            return;
        }

        // motion-off gates:
        //   - we own the lights (motion turned them on, or off-only claim)
        //   - all other sensors in this room are also inactive
        //   - lights are physically still on
        let zone = self.world.light_zone(room_name);
        if !zone.is_motion_owned() {
            tracing::info!(
                sensor,
                room = room_name,
                "motion-off suppressed: lights are user-owned, not motion-owned"
            );
            return;
        }

        // Multi-sensor OR-gate: before deciding anything we need every
        // other sensor to agree the room is vacant. If any peer still
        // reports occupied, we're still inside the current occupancy
        // session and must leave the claim untouched.
        if !self.all_other_sensors_inactive(room_name, sensor) {
            tracing::info!(
                sensor,
                room = room_name,
                "motion-off suppressed: another sensor in this room still reports active"
            );
            return;
        }

        // Fully vacant. If the zone isn't reporting on, we usually have
        // nothing to command — and in off-only mode we additionally
        // release the latched Motion claim so the next user press is
        // plain user-owned.
        //
        // The one exception is off-only with `actual.freshness() ==
        // Unknown` (no group echo has ever arrived, e.g. a degraded
        // seed): we cannot assume the lights are off, so we still
        // publish state_off defensively. Other modes keep the pre-fix
        // semantics — a redundant state_off would be noise, and this
        // path is the common echo-pending window after on-off's own
        // motion-driven off.
        let zone = self.world.light_zone(room_name);
        let actual_unknown =
            zone.actual.freshness() == ActualFreshness::Unknown;
        if !zone.is_on() {
            let defensive_off_only_publish =
                motion_mode == MotionMode::OffOnly && actual_unknown;
            if !defensive_off_only_publish {
                if motion_mode == MotionMode::OffOnly {
                    tracing::info!(
                        sensor,
                        room = room_name,
                        "off-only: vacant with lights already off → releasing motion claim"
                    );
                    zone.target.reassign_owner(Owner::System, ts);
                } else {
                    tracing::info!(
                        sensor,
                        room = room_name,
                        "motion-off suppressed: lights already physically off"
                    );
                }
                return;
            }
            tracing::info!(
                sensor,
                room = room_name,
                "off-only: vacant with unknown actual → publishing state_off defensively (lights may still be on)"
            );
            // Fall through to the state_off publish below.
        }

        tracing::info!(
            sensor,
            room = room_name,
            group = %group_name,
            transition = off_transition,
            mode = ?motion_mode,
            "motion-off → state OFF (motion-owned, all sensors clear)"
        );
        out.push(Effect::PublishGroupSet {
            room: room_idx,
            payload: Payload::state_off(off_transition),
        });
        let zone = self.world.light_zone(room_name);
        zone.target.set_and_command(LightZoneTarget::Off, Owner::Motion, ts);
        zone.last_off_at = Some(ts);
        // Arm the narrow motion cooldown — only a motion-driven off
        // should trigger the "don't re-engage for N seconds" behaviour
        // for the next live occupancy.
        zone.last_motion_off_at = Some(ts);
        self.propagate_to_descendants(room_name, false, ts);
    }

    /// When the lux/cooldown gate suppresses a motion-on event that
    /// starts a NEW occupancy session in an off-only room, release any
    /// latched Motion claim on the zone. Without this, a zombie claim
    /// (from a prior session whose sensor went Stale without ever
    /// sending `occupied=false`) would combine with the newly fresh
    /// sensor reading to backdoor `resolve_zone_owner` — the gate's
    /// "opt out" intent would be silently defeated.
    ///
    /// The `is_new_session_event` check is essential: an in-flight
    /// session that sees a repeat `occupied=true` publish (Hue sensors
    /// periodically re-publish state) must keep its claim intact.
    fn release_zombie_off_only_claim_if_gate_suppressed(
        &mut self,
        motion_mode: MotionMode,
        is_new_session_event: bool,
        room_name: &str,
        sensor: &str,
        gate: &'static str,
        ts: Instant,
    ) {
        if motion_mode != MotionMode::OffOnly || !is_new_session_event {
            return;
        }
        let zone = self.world.light_zone(room_name);
        // Only release when we're confident the prior claim is truly a
        // zombie: motion-owned AND lights aren't physically on. A
        // motion-owned + actually-on zone represents an ongoing session
        // (someone used the room; stale-sensor sweep or multi-sensor
        // OR-gate will resolve it naturally). Releasing mid-session
        // would let a gate-suppressed new-session signal from a
        // different bound sensor drop the active claim on the floor.
        //
        // We also refuse to release a `Commanded`/`Pending` target —
        // those are awaiting an echo for a command we just emitted,
        // and reassigning owner mid-flight leaves the state machine in
        // an odd "System + Commanded" split. Defer to the echo path or
        // the stale sweep.
        let phase = zone.target.phase();
        let stable_phase = matches!(
            phase,
            crate::tass::TargetPhase::Confirmed | crate::tass::TargetPhase::Stale
        );
        if zone.is_motion_owned() && !zone.actual_is_on() && stable_phase {
            tracing::info!(
                sensor,
                room = room_name,
                gate,
                "off-only: releasing prior motion claim — this new occupancy is gate-suppressed and no live session is lit"
            );
            zone.target.reassign_owner(Owner::System, ts);
        }
    }

    /// True if every other motion sensor in the room (i.e. all except
    /// `excluding`) reports inactive. Uses TASS motion sensor entities
    /// instead of the old `motion_active_by_sensor` map.
    fn all_other_sensors_inactive(&self, room_name: &str, excluding: &str) -> bool {
        let Some(room) = self.topology.room_by_name(room_name) else {
            return true;
        };
        room.bound_motion
            .iter()
            .filter(|m| m.sensor != excluding)
            .all(|m| {
                !self
                    .world
                    .motion_sensors
                    .get(&m.sensor)
                    .is_some_and(|s| s.is_occupied())
            })
    }
}

#[cfg(test)]
#[path = "motion_tests.rs"]
mod tests;
