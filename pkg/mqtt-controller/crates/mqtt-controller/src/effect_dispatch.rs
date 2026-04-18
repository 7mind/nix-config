//! Translate the typed [`Effect`] vocabulary into MQTT publishes via the
//! [`MqttBridge`]. The dispatcher is the single boundary where indexes
//! are converted back into wire-level topic strings.
//!
//! Dispatch records a [`TouchedEntities`] set so the daemon can drive
//! incremental WebSocket broadcasts from the actual side-effects
//! produced by an event, rather than re-broadcasting every room/plug/
//! heating zone after every event.

use std::collections::BTreeSet;

use crate::domain::Effect;
use crate::domain::event::Event;
use crate::domain::ha_discovery;
use crate::mqtt::{MqttBridge, MqttError};
use crate::topology::{DeviceIdx, PlugIdx, RoomIdx, Topology, ZoneIdx};

/// Set of entities touched by a batch of dispatched effects. Used by the
/// daemon's event loop to issue incremental broadcasts instead of a
/// full sweep.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TouchedEntities {
    pub rooms: BTreeSet<RoomIdx>,
    pub plugs: BTreeSet<PlugIdx>,
    pub heating_zones: BTreeSet<ZoneIdx>,
    /// Individual lights whose actual state changed.
    pub lights: BTreeSet<DeviceIdx>,
}

impl TouchedEntities {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn touch_room(&mut self, room: RoomIdx) {
        self.rooms.insert(room);
    }

    pub fn touch_plug(&mut self, plug: PlugIdx) {
        self.plugs.insert(plug);
    }

    pub fn touch_zone(&mut self, zone: ZoneIdx) {
        self.heating_zones.insert(zone);
    }

    pub fn touch_light(&mut self, light: DeviceIdx) {
        self.lights.insert(light);
    }

    /// Touch the device if it's a plug; otherwise no-op. Used by
    /// effects that target arbitrary devices (e.g. wall thermostat
    /// relays).
    pub fn touch_device_as_plug(&mut self, topology: &Topology, device: DeviceIdx) {
        if let Some(plug) = topology.plug_idx(device) {
            self.touch_plug(plug);
        }
    }

    /// If the device is a TRV that belongs to a heating zone, touch
    /// that zone too.
    pub fn touch_zone_for_trv(&mut self, topology: &Topology, trv: DeviceIdx) {
        let trv_name = topology.device_name(trv);
        if let Some(cfg) = topology.heating_config() {
            for (i, zone) in cfg.zones.iter().enumerate() {
                if zone.trvs.iter().any(|zt| zt.device == trv_name) {
                    self.touch_zone(ZoneIdx::new(i as u32));
                }
            }
        }
    }

    /// If the device is a wall thermostat that owns a heating zone,
    /// touch that zone.
    pub fn touch_zone_for_relay(&mut self, topology: &Topology, relay: DeviceIdx) {
        let relay_name = topology.device_name(relay);
        if let Some(cfg) = topology.heating_config() {
            for (i, zone) in cfg.zones.iter().enumerate() {
                if zone.relay == relay_name {
                    self.touch_zone(ZoneIdx::new(i as u32));
                }
            }
        }
    }

    /// Merge another touched-set into this one.
    pub fn extend(&mut self, other: TouchedEntities) {
        self.rooms.extend(other.rooms);
        self.plugs.extend(other.plugs);
        self.heating_zones.extend(other.heating_zones);
        self.lights.extend(other.lights);
    }
}

/// Compute the touched-entities set implied by an inbound [`Event`]
/// before [`crate::logic::EventProcessor::handle_event`] runs. Inbound
/// state events (`GroupState`, `PlugState`, telemetry) mutate
/// `WorldState` without emitting effects, so the daemon needs this
/// signal in addition to [`dispatch`]'s effect-derived set to keep
/// dashboard broadcasts honest.
pub fn touched_from_event(event: &Event, topology: &Topology) -> TouchedEntities {
    let mut touched = TouchedEntities::new();
    match event {
        Event::Occupancy { sensor, .. } => {
            for &room in topology.rooms_for_motion(sensor) {
                touched.touch_room(room);
            }
        }
        Event::GroupState { group, .. } => {
            if let Some(room) = topology.room_idx_by_group(group) {
                touched.touch_room(room);
                // Group state changes propagate to rule-bearing
                // descendant rooms (`handle_group_state` calls
                // `propagate_to_descendants`); reflect that in the
                // touched set so the dashboard updates the whole
                // affected subtree, not just the parent.
                for &desc in topology.descendants_of(room) {
                    touched.touch_room(desc);
                }
            }
        }
        Event::PlugState { device, .. } | Event::PlugPowerUpdate { device, .. } => {
            if let Some(plug_idx) = topology.plug_idx_by_name(device) {
                touched.touch_plug(plug_idx);
            }
        }
        Event::LightState { device, .. } => {
            if let Some(dev) = topology.device_idx(device) {
                touched.touch_light(dev);
            }
        }
        Event::TrvState { device, .. } => {
            if let Some(dev) = topology.device_idx(device) {
                touched.touch_zone_for_trv(topology, dev);
            }
        }
        Event::WallThermostatState { device, .. } => {
            if let Some(dev) = topology.device_idx(device) {
                touched.touch_zone_for_relay(topology, dev);
            }
        }
        Event::ButtonPress { .. } | Event::Tick { .. } => {}
    }
    touched
}

/// Translate a batch of [`Effect`]s into MQTT publishes via `bridge`,
/// returning the set of touched entities for downstream broadcast.
///
/// Errors from individual publishes are logged but do not abort the
/// batch — the rest of the side-effects still need to fire. This
/// matches the previous `for action in actions { ... }` semantics.
pub async fn dispatch(
    bridge: &MqttBridge,
    topology: &Topology,
    effects: &[Effect],
) -> TouchedEntities {
    let mut touched = TouchedEntities::new();
    for effect in effects {
        match dispatch_one(bridge, topology, effect, &mut touched).await {
            Ok(()) => {}
            Err(e) => {
                tracing::error!(error = ?e, ?effect, "failed to dispatch effect");
            }
        }
    }
    touched
}

async fn dispatch_one(
    bridge: &MqttBridge,
    topology: &Topology,
    effect: &Effect,
    touched: &mut TouchedEntities,
) -> Result<(), MqttError> {
    match effect {
        Effect::PublishGroupSet { room, payload } => {
            touched.touch_room(*room);
            // Logic propagates state to rule-bearing descendant rooms
            // (`propagate_to_descendants` / `publish_off`) when a room
            // turns on or off, so the dashboard needs updates for those
            // too.
            for &desc in topology.descendants_of(*room) {
                touched.touch_room(desc);
            }
            let group_name = topology.room(*room).group_name.clone();
            bridge.publish_group_set(&group_name, payload).await
        }
        Effect::PublishDeviceSet { device, payload } => {
            // Touch device's plug (if it's a plug) or its zone (if it's
            // a TRV or relay) so downstream broadcast covers the right
            // entity.
            touched.touch_device_as_plug(topology, *device);
            touched.touch_zone_for_trv(topology, *device);
            touched.touch_zone_for_relay(topology, *device);
            let device_name = topology.device_name(*device).to_string();
            let is_zwave = topology.is_zwave_plug_idx(*device);
            bridge.publish_device_set(&device_name, payload, is_zwave).await
        }
        Effect::PublishDeviceGet { device } => {
            let device_name = topology.device_name(*device);
            bridge.publish_get(device_name).await
        }
        Effect::PublishHaDiscoveryZone { zone } => {
            let cfg = topology
                .heating_config()
                .expect("zone effect requires heating config");
            let zone_cfg = &cfg.zones[zone.as_usize()];
            let publish = ha_discovery::zone_discovery_publish(&zone_cfg.name);
            bridge.publish_raw(&publish.topic, publish.payload.as_bytes(), true).await
        }
        Effect::PublishHaDiscoveryTrv { trv } => {
            let trv_name = topology.device_name(*trv);
            let publish = ha_discovery::trv_discovery_publish(trv_name);
            bridge.publish_raw(&publish.topic, publish.payload.as_bytes(), true).await
        }
        Effect::PublishHaStateZone { zone, state } => {
            touched.touch_zone(*zone);
            let cfg = topology
                .heating_config()
                .expect("zone effect requires heating config");
            let zone_cfg = &cfg.zones[zone.as_usize()];
            let topic = ha_discovery::state_topic("zone", &zone_cfg.name);
            bridge.publish_raw(&topic, state.as_bytes(), true).await
        }
        Effect::PublishHaStateTrv { trv, state } => {
            touched.touch_zone_for_trv(topology, *trv);
            let trv_name = topology.device_name(*trv);
            let topic = ha_discovery::state_topic("trv", trv_name);
            bridge.publish_raw(&topic, state.as_bytes(), true).await
        }
        Effect::PublishRaw { topic, payload, retain } => {
            bridge.publish_raw(topic, payload.as_bytes(), *retain).await
        }
    }
}

#[cfg(test)]
#[path = "effect_dispatch_tests.rs"]
mod tests;
