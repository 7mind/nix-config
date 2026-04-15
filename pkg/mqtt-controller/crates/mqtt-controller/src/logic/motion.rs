//! Motion-sensor dispatch: occupancy gating, multi-sensor OR-gate,
//! illuminance gate, cooldown gate.
//!
//! Ports [`crate::controller::motion`] to TASS entities. Per-sensor
//! occupancy flags are now stored in [`MotionSensorEntity`] actual
//! state instead of the `motion_active_by_sensor` map. Motion
//! ownership is tracked via [`LightZoneEntity::is_motion_owned()`]
//! (target owner == Motion).

use std::time::{Duration, Instant};

use crate::domain::action::{Action, Payload};
use crate::entities::light_zone::LightZoneTarget;
use crate::entities::motion_sensor::MotionActual;
use crate::tass::Owner;
use crate::topology::RoomName;

use super::EventProcessor;

impl EventProcessor {
    pub(super) fn handle_occupancy(
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
        let sun = self.sun_times();
        let (group_name, max_lux, cooldown_ms, off_transition, scenes_for_now) = {
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
            )
        };

        // Dedup for repeated false: z2m re-publishes the full sensor state
        // on *any* attribute change (temperature, illuminance, battery).
        // Each publish includes the current `occupancy` value even when it
        // hasn't changed, flooding the log with suppression messages every
        // ~10 seconds. For repeated `occupied: false` events the outcome
        // is always the same (motion-off was already processed on the real
        // transition), so skip them. We do NOT dedup repeated `occupied:
        // true` because external state may change between publishes
        // (cooldown expires, illuminance decreases) and re-evaluation is
        // required.
        let prev_occupied = self
            .world
            .motion_sensors
            .get(sensor)
            .and_then(|s| s.actual.value())
            .map(|a| a.occupied);

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

        if occupied {
            // motion-on gates:
            //   - room currently off
            //   - illuminance < max (or no gate)
            //   - cooldown expired
            let zone = self.world.light_zone(room_name);
            if zone.is_on() {
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
            let last_off = self.world.light_zone(room_name).last_off_at;
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
            let zone = self.world.light_zone(room_name);
            zone.target.set_and_command(
                LightZoneTarget::On { scene_id: first, cycle_idx: 0 },
                Owner::Motion,
                ts,
            );
            // Don't touch last_press_at -- this isn't a button press.
            self.propagate_to_descendants(room_name, true, ts);
        } else {
            // motion-off gates:
            //   - we own the lights (motion turned them on)
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
            if !zone.is_on() {
                tracing::info!(
                    sensor,
                    room = room_name,
                    "motion-off suppressed: lights already physically off"
                );
                return;
            }

            // Multi-sensor OR-gate: check all other motion sensors bound
            // to this room. If any other sensor still reports occupied,
            // suppress the off.
            if !self.all_other_sensors_inactive(room_name, sensor) {
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
            let zone = self.world.light_zone(room_name);
            zone.target.set_and_command(LightZoneTarget::Off, Owner::Motion, ts);
            zone.last_off_at = Some(ts);
            self.propagate_to_descendants(room_name, false, ts);
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
