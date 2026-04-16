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
use crate::domain::action::{Action, ActionTarget, Payload};
use crate::mqtt::{MqttBridge, MqttError};
use crate::topology::{DeviceIdx, PlugIdx, RoomIdx, Topology, ZoneIdx};

/// Translate a legacy [`Action`] into an [`Effect`] using the topology
/// to resolve string names to indexes. Used during the migration from
/// `Vec<Action>` returning logic to `Vec<Effect>` returning logic.
///
/// Returns `None` if the action references a name that's not in the
/// topology (for `Group` and `Device` targets) — the caller's logic
/// should never produce such actions, but if it does we drop them
/// silently rather than panicking.
pub fn action_to_effect(action: Action, topology: &Topology) -> Option<Effect> {
    match action.target {
        ActionTarget::Group(group_name) => {
            let room = topology.room_idx_by_group(&group_name)?;
            Some(Effect::PublishGroupSet { room, payload: action.payload })
        }
        ActionTarget::Device(device_name) => {
            let device = topology.device_idx(&device_name)?;
            Some(Effect::PublishDeviceSet { device, payload: action.payload })
        }
        ActionTarget::DeviceGet(device_name) => {
            let device = topology.device_idx(&device_name)?;
            Some(Effect::PublishDeviceGet { device })
        }
        ActionTarget::Raw { topic, retain } => {
            // Only `RawString` payloads make sense for raw publishes;
            // other payload variants serialize to JSON which is not
            // what callers expect for HA discovery / state updates.
            let payload = match action.payload {
                Payload::RawString(s) => s,
                other => serde_json::to_string(&other).unwrap_or_default(),
            };
            Some(Effect::PublishRaw { topic, payload, retain })
        }
    }
}

/// Convenience: translate a slice of actions into effects, dropping
/// any that don't resolve. Used by the daemon's command handlers
/// during the migration.
pub fn actions_to_effects(actions: Vec<Action>, topology: &Topology) -> Vec<Effect> {
    actions
        .into_iter()
        .filter_map(|a| action_to_effect(a, topology))
        .collect()
}

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
            let action = crate::domain::ha_discovery::zone_discovery_action(&zone_cfg.name);
            publish_legacy_action(bridge, &action).await
        }
        Effect::PublishHaDiscoveryTrv { trv } => {
            let trv_name = topology.device_name(*trv);
            let action = crate::domain::ha_discovery::trv_discovery_action(trv_name);
            publish_legacy_action(bridge, &action).await
        }
        Effect::PublishHaStateZone { zone, state } => {
            touched.touch_zone(*zone);
            let cfg = topology
                .heating_config()
                .expect("zone effect requires heating config");
            let zone_cfg = &cfg.zones[zone.as_usize()];
            let action =
                crate::domain::ha_discovery::state_update_action("zone", &zone_cfg.name, state);
            publish_legacy_action(bridge, &action).await
        }
        Effect::PublishHaStateTrv { trv, state } => {
            touched.touch_zone_for_trv(topology, *trv);
            let trv_name = topology.device_name(*trv);
            let action =
                crate::domain::ha_discovery::state_update_action("trv", trv_name, state);
            publish_legacy_action(bridge, &action).await
        }
        Effect::PublishRaw { topic, payload, retain } => {
            bridge.publish_raw(topic, payload.as_bytes(), *retain).await
        }
    }
}

/// Helper for HA discovery / state update actions which currently
/// produce a legacy [`crate::domain::action::Action`] with a `Raw`
/// target. Translates that wrapper into the underlying MQTT publish.
async fn publish_legacy_action(
    bridge: &MqttBridge,
    action: &crate::domain::action::Action,
) -> Result<(), MqttError> {
    use crate::domain::action::ActionTarget;
    match &action.target {
        ActionTarget::Raw { topic, retain } => {
            let bytes = match &action.payload {
                Payload::RawString(s) => s.as_bytes().to_vec(),
                other => serde_json::to_vec(other)?,
            };
            bridge.publish_raw(topic, &bytes, *retain).await
        }
        _ => unreachable!("HA discovery actions are always Raw"),
    }
}
