use std::collections::{BTreeMap, BTreeSet};

use super::{
    LightEndpoint, MotionBinding, MotionRuleIdx, ResolvedMotionRule, ResolvedMotionTarget,
    Topology, TopologyError,
};
use crate::config::{Config, DeviceCatalogEntry, MotionTarget};

impl Topology {
    pub(super) fn build_motion_rules(&mut self, config: &Config) -> Result<(), TopologyError> {
        let mut names = BTreeSet::new();
        let mut owners = BTreeMap::new();
        for rule in &config.motion_rules {
            let invalid = |reason: String| TopologyError::InvalidMotionRule {
                rule: rule.name.clone(),
                reason,
            };
            if rule.name.is_empty() || !names.insert(rule.name.clone()) {
                return Err(invalid("name must be nonempty and unique".into()));
            }
            if rule.sensors.is_empty()
                || rule.sensors.iter().collect::<BTreeSet<_>>().len() != rule.sensors.len()
            {
                return Err(invalid("sensors must be nonempty and unique".into()));
            }
            if !rule.off_transition_seconds.is_finite() || rule.off_transition_seconds < 0.0 {
                return Err(invalid(
                    "off transition must be finite and nonnegative".into(),
                ));
            }
            rule.scenes
                .validate()
                .map_err(|error| invalid(error.to_string()))?;
            if rule.scenes.uses_sun_expressions() && config.location.is_none() {
                return Err(TopologyError::MissingLocationForSunExpressions);
            }
            if rule.scenes.slots.is_empty()
                || rule.targets_by_slot.keys().ne(rule.scenes.slots.keys())
            {
                return Err(invalid(
                    "targets_by_slot must contain exactly the scene schedule's slots".into(),
                ));
            }
            let mut sensors = Vec::new();
            for name in &rule.sensors {
                match config.devices.get(name) {
                    Some(DeviceCatalogEntry::MotionSensor {
                        occupancy_timeout_seconds,
                        ..
                    }) => {
                        sensors.push(MotionBinding {
                            sensor: name.clone(),
                            occupancy_timeout_seconds: *occupancy_timeout_seconds,
                        });
                    }
                    _ => {
                        return Err(invalid(format!(
                            "sensor {name:?} is not a motion sensor in the catalog"
                        )));
                    }
                }
            }
            let mut targets = BTreeMap::new();
            let mut lights = BTreeSet::new();
            for (slot_name, target) in &rule.targets_by_slot {
                let slot = &rule.scenes.slots[slot_name];
                if slot.scene_ids.is_empty() {
                    return Err(invalid(format!("slot {slot_name:?} has no scenes")));
                }
                for id in &slot.scene_ids {
                    let scene = rule
                        .scenes
                        .scenes
                        .iter()
                        .find(|scene| scene.id == *id)
                        .expect("validated scene id");
                    if scene.state != "ON"
                        || !scene.transition.is_finite()
                        || scene.transition < 0.0
                    {
                        return Err(invalid(format!(
                            "scene {id} must turn lights ON and have a finite nonnegative transition"
                        )));
                    }
                }
                let resolved = match target {
                    MotionTarget::Group { group } => {
                        let idx = self
                            .room_idx(group)
                            .ok_or_else(|| invalid(format!("unknown group {group:?}")))?;
                        let room = self.room(idx);
                        for id in &slot.scene_ids {
                            let scene = rule
                                .scenes
                                .scenes
                                .iter()
                                .find(|scene| scene.id == *id)
                                .expect("validated scene id");
                            if !room.scenes.scenes.contains(scene) {
                                return Err(invalid(format!(
                                    "scene {id} differs from the provisioned scenes of group {group:?}"
                                )));
                            }
                        }
                        ResolvedMotionTarget {
                            group: Some(idx),
                            lights: room.light_members.clone(),
                        }
                    }
                    MotionTarget::Lights { lights: members } => {
                        let mut endpoints = Vec::new();
                        for member in members {
                            let (name, endpoint) = member.rsplit_once('/').ok_or_else(|| {
                                invalid(format!("invalid light endpoint {member:?}"))
                            })?;
                            let device = self
                                .device_idx(name)
                                .ok_or_else(|| invalid(format!("unknown light {name:?}")))?;
                            let endpoint = endpoint
                                .parse::<u8>()
                                .ok()
                                .filter(|e| (1..=240).contains(e))
                                .ok_or_else(|| {
                                    invalid(format!("invalid light endpoint {member:?}"))
                                })?;
                            let light = LightEndpoint { device, endpoint };
                            if !self
                                .rooms
                                .iter()
                                .any(|room| room.light_members.contains(&light))
                            {
                                return Err(invalid(format!(
                                    "light endpoint {member:?} is not a configured group member"
                                )));
                            }
                            endpoints.push(light);
                        }
                        ResolvedMotionTarget {
                            group: None,
                            lights: endpoints,
                        }
                    }
                };
                if resolved.lights.is_empty()
                    || resolved.lights.iter().collect::<BTreeSet<_>>().len()
                        != resolved.lights.len()
                {
                    return Err(invalid(format!(
                        "slot {slot_name:?} must target nonempty, unique light endpoints"
                    )));
                }
                lights.extend(resolved.lights.iter().copied());
                targets.insert(slot_name.clone(), resolved);
            }
            for light in &lights {
                if let Some(other) = owners.insert(light.device, rule.name.clone()) {
                    return Err(invalid(format!(
                        "light {:?} is also targeted by motion rule {other:?}",
                        self.device_name(light.device)
                    )));
                }
                // State reports in the current light catalog have one actual value per device.
                let endpoints: BTreeSet<_> = self
                    .rooms
                    .iter()
                    .flat_map(|room| &room.light_members)
                    .filter(|member| member.device == light.device)
                    .map(|member| member.endpoint)
                    .collect();
                if endpoints.len() != 1 {
                    return Err(invalid(format!(
                        "light {:?} has multiple endpoints; endpoint-specific telemetry is required for motion control",
                        self.device_name(light.device)
                    )));
                }
            }
            let related_rooms: Vec<_> = self
                .rooms_with_idx()
                .filter_map(|(idx, room)| {
                    room.light_members
                        .iter()
                        .any(|member| lights.contains(member))
                        .then_some(idx)
                })
                .collect();
            let idx = MotionRuleIdx::new(self.motion_rules.len() as u32);
            for sensor in &sensors {
                let device = self.device_idx(&sensor.sensor).expect("validated sensor");
                self.motion_rule_index.entry(device).or_default().push(idx);
                let rooms = self.motion_index.entry(device).or_default();
                for room in &related_rooms {
                    if !rooms.contains(room) {
                        rooms.push(*room);
                    }
                    let bound = &mut self.rooms[room.as_usize()].bound_motion;
                    if !bound.iter().any(|entry| entry.sensor == sensor.sensor) {
                        bound.push(sensor.clone());
                    }
                }
            }
            self.motion_rules.push(ResolvedMotionRule {
                name: rule.name.clone(),
                sensors,
                mode: rule.mode,
                scenes: rule.scenes.clone(),
                targets_by_slot: targets,
                off_transition_seconds: rule.off_transition_seconds,
                off_cooldown_seconds: rule.off_cooldown_seconds,
                max_illuminance: rule.max_illuminance,
                lights: lights.into_iter().collect(),
                rooms: related_rooms,
            });
        }
        // Include motion-controlled descendants in the same index as button-controlled groups.
        for (parent, _) in self.rooms.iter().enumerate() {
            let mut descendants = BTreeSet::new();
            for (child, room) in self.rooms.iter().enumerate() {
                if room.bound_motion.is_empty() && !self.room_has_bindings[child] {
                    continue;
                }
                let mut ancestor = room.parent.as_deref();
                while let Some(name) = ancestor {
                    let idx = self.room_idx(name).expect("validated parent");
                    if idx.as_usize() == parent {
                        descendants.insert(super::RoomIdx::new(child as u32));
                    }
                    ancestor = self.room(idx).parent.as_deref();
                }
            }
            let mut descendants: Vec<_> = descendants.into_iter().collect();
            descendants.sort_by_key(|idx| self.room(*idx).name.clone());
            self.descendants_by_room.push(descendants);
        }
        Ok(())
    }
}
