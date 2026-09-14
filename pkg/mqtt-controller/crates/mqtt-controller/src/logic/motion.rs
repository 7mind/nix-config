//! Motion rules own occupancy sessions; lights own actuator targets.
use std::collections::BTreeSet;
use std::time::{Duration, Instant};

use super::EventProcessor;
use crate::config::MotionMode;
use crate::domain::{Effect, action::Payload};
use crate::entities::light::LightTarget;
use crate::entities::light_zone::LightZoneTarget;
use crate::entities::motion_rule::MotionSession;
use crate::entities::motion_sensor::MotionActual;
use crate::tass::{Owner, TargetPhase};
use crate::topology::{
    DeviceIdx, LightEndpoint, ResolvedMotionRule, ResolvedMotionTarget, RoomIdx,
};

impl EventProcessor {
    pub(super) fn motion_rule_occupied(&self, rule: &ResolvedMotionRule) -> bool {
        rule.sensors.iter().any(|sensor| {
            self.world
                .motion_sensors
                .get(&sensor.sensor)
                .is_some_and(|entity| entity.is_occupied())
        })
    }

    pub(super) fn handle_occupancy(
        &mut self,
        sensor: &str,
        occupied: bool,
        illuminance: Option<u32>,
        ts: Instant,
    ) -> Vec<Effect> {
        let rules: Vec<_> = self
            .topology
            .motion_rules_for_sensor(sensor)
            .iter()
            .map(|idx| self.topology.motion_rule(*idx).clone())
            .collect();
        let previous = self.world.motion_sensors.get(sensor);
        let was_occupied = previous.is_some_and(|sensor| sensor.is_occupied());
        let was_clear = previous
            .and_then(|sensor| sensor.actual.value())
            .is_some_and(|actual| !actual.occupied);
        let previously_active: Vec<_> = rules
            .iter()
            .map(|rule| self.motion_rule_occupied(rule))
            .collect();
        self.world.motion_sensor(sensor).actual.update(
            MotionActual {
                occupied,
                illuminance,
            },
            ts,
        );
        if (occupied && was_occupied) || (!occupied && was_clear) {
            return Vec::new();
        }
        let mut effects = Vec::new();
        for (rule, was_active) in rules.iter().zip(previously_active) {
            if occupied {
                if was_active
                    && self
                        .world
                        .motion_rules
                        .get(&rule.name)
                        .is_some_and(|state| state.session.is_some())
                {
                    continue;
                }
                if !was_active {
                    let ended = self
                        .world
                        .motion_rules
                        .get(&rule.name)
                        .and_then(|state| state.session.as_ref())
                        .is_some_and(|session| self.motion_target_is_off(&session.target));
                    if ended {
                        self.release_motion_session(rule, ts);
                    }
                }
                if self
                    .world
                    .motion_rules
                    .get(&rule.name)
                    .is_some_and(|state| state.session.is_some())
                {
                    continue;
                }
                effects.extend(self.start_motion_session(rule, illuminance, ts));
            } else if !self.motion_rule_occupied(rule) {
                effects.extend(self.finish_motion_session(rule, ts, Owner::Motion));
            }
        }
        effects
    }

    fn start_motion_session(
        &mut self,
        rule: &ResolvedMotionRule,
        illuminance: Option<u32>,
        ts: Instant,
    ) -> Vec<Effect> {
        let max_lux = rule.max_illuminance;
        let last_off = self
            .world
            .motion_rules
            .get(&rule.name)
            .and_then(|state| state.last_motion_off_at);
        let bright = matches!((max_lux, illuminance), (Some(max), Some(actual)) if actual >= max);
        let cooling = last_off.is_some_and(|last| {
            ts.duration_since(last) < Duration::from_secs(u64::from(rule.off_cooldown_seconds))
        });
        if bright || cooling {
            tracing::info!(rule = %rule.name, bright, cooling, "motion activation suppressed");
            return Vec::new();
        }
        let sun = self.sun_times();
        let Some((slot_name, slot)) = rule.scenes.slot_for_time(
            self.clock.local_hour(),
            self.clock.local_minute(),
            sun.as_ref(),
        ) else {
            tracing::error!(rule = %rule.name, "motion schedule has no active slot; activation suppressed");
            return Vec::new();
        };
        let target = rule.targets_by_slot[slot_name].clone();
        let scene_id = slot.scene_ids[0];
        let scene = rule
            .scenes
            .scenes
            .iter()
            .find(|scene| scene.id == scene_id)
            .expect("validated scene");
        if rule.mode != MotionMode::OffOnly {
            if let Some(group) = target.group {
                let name = self.topology.room(group).name.clone();
                if self.world.light_zone(&name).is_on() {
                    return Vec::new();
                }
            }
        }
        let mut claimed = BTreeSet::new();
        for endpoint in &target.lights {
            let name = self.topology.device_name(endpoint.device).to_string();
            let light = self.world.light(&name);
            if rule.mode == MotionMode::OffOnly {
                let divergent = light
                    .target
                    .value()
                    .zip(light.actual.value())
                    .is_some_and(|(target, actual)| !target.matches(actual));
                if light.target.is_unset()
                    || (light.target.phase() == TargetPhase::Stale && divergent)
                {
                    let value = if light.actual.value().is_some_and(|actual| actual.on) {
                        LightTarget::On {
                            brightness: None,
                            color_temp: None,
                        }
                    } else {
                        LightTarget::Off
                    };
                    light.target.adopt(value, Owner::Motion, ts);
                } else if light.target.owner() != Some(Owner::Motion) {
                    light.target.reassign_owner(Owner::Motion, ts);
                }
                claimed.insert(endpoint.device);
            } else if !light.is_on() {
                let owner = if rule.mode == MotionMode::OnOnly {
                    Owner::User
                } else {
                    Owner::Motion
                };
                light.target.set_and_command(
                    LightTarget::On {
                        brightness: scene.brightness,
                        color_temp: scene.color_temp,
                    },
                    owner,
                    ts,
                );
                claimed.insert(endpoint.device);
            }
        }
        if claimed.is_empty() {
            return Vec::new();
        }
        self.world
            .motion_rules
            .entry(rule.name.clone())
            .or_default()
            .session = Some(MotionSession {
            slot: slot_name.clone(),
            target: target.clone(),
            claimed: claimed.clone(),
        });
        tracing::info!(rule = %rule.name, slot = %slot_name, lights = claimed.len(), mode = ?rule.mode, "motion session started");
        if rule.mode == MotionMode::OffOnly {
            if let Some(group) = target.group {
                self.adopt_off_only_group(group, ts);
            }
            return Vec::new();
        }
        let owner = if rule.mode == MotionMode::OnOnly {
            Owner::User
        } else {
            Owner::Motion
        };
        if let Some(group) = target.group {
            if claimed.len() == target.lights.len() {
                let name = self.topology.room(group).name.clone();
                self.world.light_zone(&name).target.set_and_command(
                    LightZoneTarget::On {
                        scene_id,
                        cycle_idx: 0,
                    },
                    owner,
                    ts,
                );
                return vec![Effect::PublishGroupSet {
                    room: group,
                    payload: Payload::scene_recall(scene_id),
                }];
            }
        }
        target
            .lights
            .iter()
            .filter(|light| claimed.contains(&light.device))
            .map(|light| Effect::PublishLightSet {
                light: *light,
                payload: Payload::light_on(scene),
            })
            .collect()
    }

    fn adopt_off_only_group(&mut self, group: RoomIdx, ts: Instant) {
        let name = self.topology.room(group).name.clone();
        let zone = self.world.light_zone(&name);
        let divergent = zone.target_is_on() != zone.actual_is_on();
        if zone.target.is_unset() || (zone.target.phase() == TargetPhase::Stale && divergent) {
            let value = if zone.actual_is_on() {
                LightZoneTarget::On {
                    scene_id: 0,
                    cycle_idx: 0,
                }
            } else {
                LightZoneTarget::Off
            };
            zone.target.adopt(value, Owner::Motion, ts);
        } else if zone.target.owner() != Some(Owner::Motion) {
            zone.target.reassign_owner(Owner::Motion, ts);
        }
    }

    fn motion_target_is_off(&self, target: &ResolvedMotionTarget) -> bool {
        let group_off = target.group.is_some_and(|group| {
            self.world
                .light_zones
                .get(&self.topology.room(group).name)
                .is_some_and(|zone| {
                    zone.actual.value() == Some(&crate::entities::light_zone::LightZoneActual::Off)
                        && !zone.target_is_on()
                })
        });
        target.lights.iter().all(|endpoint| {
            self.world
                .lights
                .get(self.topology.device_name(endpoint.device))
                .is_some_and(|light| {
                    !matches!(light.target.value(), Some(LightTarget::On { .. }))
                        && (group_off || light.actual.value().is_some_and(|actual| !actual.on))
                })
        })
    }

    fn release_motion_session(&mut self, rule: &ResolvedMotionRule, ts: Instant) {
        if let Some(session) = self
            .world
            .motion_rules
            .get_mut(&rule.name)
            .and_then(|state| state.session.take())
        {
            for endpoint in session.target.lights {
                let name = self.topology.device_name(endpoint.device).to_string();
                let light = self.world.light(&name);
                if light.target.owner() == Some(Owner::Motion) {
                    light.target.reassign_owner(Owner::System, ts);
                }
            }
            if let Some(group) = session.target.group {
                let name = self.topology.room(group).name.clone();
                let zone = self.world.light_zone(&name);
                if zone.is_motion_owned() {
                    zone.target.reassign_owner(Owner::System, ts);
                }
            }
        }
    }

    pub(super) fn finish_motion_session(
        &mut self,
        rule: &ResolvedMotionRule,
        ts: Instant,
        owner: Owner,
    ) -> Vec<Effect> {
        if self
            .world
            .motion_rules
            .get(&rule.name)
            .and_then(|state| state.session.as_ref())
            .is_some_and(|session| self.motion_target_is_off(&session.target))
        {
            self.release_motion_session(rule, ts);
            return Vec::new();
        }
        let session = self
            .world
            .motion_rules
            .get_mut(&rule.name)
            .and_then(|state| state.session.take());
        let Some(session) = session else {
            return Vec::new();
        };
        if rule.mode == MotionMode::OnOnly {
            return Vec::new();
        }
        let eligible: Vec<_> = session
            .target
            .lights
            .iter()
            .filter(|endpoint| {
                session.claimed.contains(&endpoint.device)
                    && self
                        .world
                        .lights
                        .get(self.topology.device_name(endpoint.device))
                        .is_some_and(|light| light.target.owner() == Some(Owner::Motion))
            })
            .copied()
            .collect();
        if eligible.is_empty() {
            return Vec::new();
        }
        let effects = self.turn_off_motion_lights(
            &session.target,
            &eligible,
            rule.off_transition_seconds,
            ts,
            owner,
        );
        if !effects.is_empty() {
            self.world
                .motion_rules
                .entry(rule.name.clone())
                .or_default()
                .last_motion_off_at = Some(ts);
            tracing::info!(rule = %rule.name, slot = %session.slot, lights = eligible.len(), "motion session ended: all sensors inactive");
        }
        effects
    }

    fn turn_off_motion_lights(
        &mut self,
        target: &ResolvedMotionTarget,
        lights: &[LightEndpoint],
        transition: f64,
        ts: Instant,
        owner: Owner,
    ) -> Vec<Effect> {
        for endpoint in lights {
            let name = self.topology.device_name(endpoint.device).to_string();
            self.world
                .light(&name)
                .target
                .set_and_command(LightTarget::Off, owner, ts);
        }
        if let Some(group) = target.group {
            if lights.len() == target.lights.len() {
                let name = self.topology.room(group).name.clone();
                let zone = self.world.light_zone(&name);
                zone.target.set_and_command(LightZoneTarget::Off, owner, ts);
                zone.last_off_at = Some(ts);
                zone.last_motion_off_at = Some(ts);
                return vec![Effect::PublishGroupSet {
                    room: group,
                    payload: Payload::state_off(transition),
                }];
            }
        }
        lights
            .iter()
            .map(|light| Effect::PublishLightSet {
                light: *light,
                payload: Payload::state_off(transition),
            })
            .collect()
    }

    pub(super) fn light_has_off_only_claim(&self, device: DeviceIdx) -> bool {
        self.topology.motion_rules().iter().any(|rule| {
            rule.mode == MotionMode::OffOnly
                && self.motion_rule_occupied(rule)
                && self
                    .world
                    .motion_rules
                    .get(&rule.name)
                    .and_then(|state| state.session.as_ref())
                    .is_some_and(|session| session.claimed.contains(&device))
        })
    }

    pub(super) fn record_group_light_command(
        &mut self,
        room_name: &str,
        target: LightTarget,
        owner: Owner,
        ts: Instant,
    ) {
        let Some(room) = self.topology.room_by_name(room_name) else {
            return;
        };
        let lights = room.light_members.clone();
        for endpoint in lights {
            let owner = if self.light_has_off_only_claim(endpoint.device) {
                Owner::Motion
            } else if owner == Owner::Motion {
                Owner::User
            } else {
                owner
            };
            let name = self.topology.device_name(endpoint.device).to_string();
            self.world
                .light(&name)
                .target
                .set_and_command(target.clone(), owner, ts);
        }
    }

    /// Startup retains the existing explicit reset policy, applied to the union
    /// of a rule's targets so a restart across a slot boundary cannot strand lights.
    pub fn startup_turn_off_motion_zones(&mut self, ts: Instant) -> Vec<Effect> {
        let rules = self.topology.motion_rules().to_vec();
        let mut effects = Vec::new();
        for rule in rules {
            if rule.mode == MotionMode::OnOnly {
                continue;
            }
            let observed_on = rule.lights.iter().any(|light| {
                self.world
                    .lights
                    .get(self.topology.device_name(light.device))
                    .is_some_and(|entity| entity.actual.value().is_some_and(|actual| actual.on))
            }) || rule
                .targets_by_slot
                .values()
                .filter_map(|target| target.group)
                .any(|group| {
                    self.world
                        .light_zones
                        .get(&self.topology.room(group).name)
                        .is_some_and(|zone| zone.actual_is_on())
                });
            if !observed_on {
                continue;
            }
            if rule.mode == MotionMode::OffOnly && self.motion_rule_occupied(&rule) {
                effects.extend(self.start_motion_session(&rule, None, ts));
                continue;
            }
            let group = rule
                .targets_by_slot
                .values()
                .find(|target| {
                    target.group.is_some()
                        && target.lights.iter().copied().collect::<BTreeSet<_>>()
                            == rule.lights.iter().copied().collect()
                })
                .and_then(|target| target.group);
            let target = ResolvedMotionTarget {
                group,
                lights: rule.lights.clone(),
            };
            effects.extend(self.turn_off_motion_lights(
                &target,
                &rule.lights,
                rule.off_transition_seconds,
                ts,
                Owner::System,
            ));
            if let Some(group) = group {
                // Reset commands do not arm the motion cooldown.
                let name = self.topology.room(group).name.clone();
                self.world.light_zone(&name).last_motion_off_at = None;
            }
        }
        effects
    }
}

#[cfg(test)]
#[path = "motion_tests.rs"]
mod tests;
