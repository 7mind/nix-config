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
        Effect::PublishGetTrv { trv } => {
            let device_name = topology.device_name(*trv);
            bridge.publish_get_trv(device_name).await
        }
        Effect::PublishZwaveRefresh { plug } => {
            // Need the node_id; look it up in the zwave_node_id map
            // (which stores the inverse of what we want).
            let dev_idx = plug.device();
            // Find the node_id for this plug device.
            let device_name = topology.device_name(dev_idx);
            let node_id = topology
                .zwave_node_id_to_name()
                .into_iter()
                .find(|(_, name)| *name == device_name)
                .map(|(id, _)| id);
            if let Some(node_id) = node_id {
                bridge.publish_zwave_refresh(node_id).await
            } else {
                Ok(())
            }
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

