//! Typed effects flowing OUT of the controller. Every state-machine
//! transition returns a `Vec<Effect>`; the [`crate::effect_dispatch`]
//! module translates each effect into the corresponding MQTT publish
//! via the [`crate::mqtt::MqttBridge`] handle.
//!
//! All effects reference rooms, devices, plugs, and heating zones by
//! typed index ([`RoomIdx`], [`DeviceIdx`], [`PlugIdx`], [`ZoneIdx`])
//! resolved against the topology at build time. The dispatch layer is
//! the only place that turns indexes back into MQTT topic strings.

use crate::domain::action::Payload;
use crate::domain::ha_discovery;
use crate::mqtt::topics;
use crate::topology::{DeviceIdx, RoomIdx, Topology, ZoneIdx};

/// One thing the controller wants to publish to MQTT, expressed in
/// terms of typed topology indexes.
#[derive(Debug, Clone, PartialEq)]
#[allow(clippy::large_enum_variant)]
pub enum Effect {
    /// Publish to `zigbee2mqtt/<group>/set` for the room's z2m group.
    PublishGroupSet { room: RoomIdx, payload: Payload },

    /// Publish to `zigbee2mqtt/<device>/set` for the device.
    PublishDeviceSet { device: DeviceIdx, payload: Payload },

    /// Publish `{"state":""}` to `zigbee2mqtt/<device>/get` to force
    /// z2m to query and re-publish the device's current state. Used at
    /// runtime by the heating controller (wall thermostat keepalive);
    /// startup seed hits the WebSocket API instead.
    PublishDeviceGet { device: DeviceIdx },

    /// Publish the retained HA discovery config for a heating zone.
    PublishHaDiscoveryZone { zone: ZoneIdx },

    /// Publish the retained HA discovery config for a TRV.
    PublishHaDiscoveryTrv { trv: DeviceIdx },

    /// Publish the derived state string for a heating zone.
    PublishHaStateZone { zone: ZoneIdx, state: &'static str },

    /// Publish the derived state string for a TRV.
    PublishHaStateTrv { trv: DeviceIdx, state: &'static str },

    /// Escape hatch for arbitrary MQTT publishes that don't fit the
    /// typed variants. Use sparingly.
    PublishRaw { topic: String, payload: String, retain: bool },
}

impl Effect {
    /// The payload this effect will publish, if any. Used by tests to
    /// assert on the shape of emitted commands.
    pub fn payload(&self) -> Option<&Payload> {
        match self {
            Effect::PublishGroupSet { payload, .. }
            | Effect::PublishDeviceSet { payload, .. } => Some(payload),
            _ => None,
        }
    }

    /// The targeted device, if any. Used by tests and the touched-set
    /// computation.
    pub fn target_device(&self) -> Option<DeviceIdx> {
        match self {
            Effect::PublishDeviceSet { device, .. }
            | Effect::PublishDeviceGet { device }
            | Effect::PublishHaDiscoveryTrv { trv: device }
            | Effect::PublishHaStateTrv { trv: device, .. } => Some(*device),
            _ => None,
        }
    }

    /// The targeted room, if any.
    pub fn target_room(&self) -> Option<RoomIdx> {
        match self {
            Effect::PublishGroupSet { room, .. } => Some(*room),
            _ => None,
        }
    }

    /// MQTT topic this effect would publish to. Used by tests / logs;
    /// the dispatcher composes the same topic implicitly when calling
    /// the typed `MqttBridge` methods.
    pub fn topic(&self, topology: &Topology) -> String {
        match self {
            Effect::PublishGroupSet { room, .. } => {
                topics::set_topic(&topology.room(*room).group_name)
            }
            Effect::PublishDeviceSet { device, .. } => {
                if topology.is_zwave_plug_idx(*device) {
                    topics::zwave_switch_set_topic(topology.device_name(*device))
                } else {
                    topics::set_topic(topology.device_name(*device))
                }
            }
            Effect::PublishDeviceGet { device } => {
                topics::get_topic(topology.device_name(*device))
            }
            Effect::PublishHaDiscoveryZone { zone } => {
                let name = zone_name(topology, *zone);
                ha_discovery::discovery_topic("zone", &name)
            }
            Effect::PublishHaDiscoveryTrv { trv } => {
                ha_discovery::discovery_topic("trv", topology.device_name(*trv))
            }
            Effect::PublishHaStateZone { zone, .. } => {
                let name = zone_name(topology, *zone);
                ha_discovery::state_topic("zone", &name)
            }
            Effect::PublishHaStateTrv { trv, .. } => {
                ha_discovery::state_topic("trv", topology.device_name(*trv))
            }
            Effect::PublishRaw { topic, .. } => topic.clone(),
        }
    }

    /// Serialized form of the payload. Lossy for non-JSON variants
    /// (HA state strings, Z-Wave refresh, etc.) — only intended for
    /// tests, logs, and the decision-trace UI.
    pub fn payload_string(&self) -> String {
        match self {
            Effect::PublishGroupSet { payload, .. }
            | Effect::PublishDeviceSet { payload, .. } => {
                serde_json::to_string(payload).unwrap_or_default()
            }
            Effect::PublishDeviceGet { .. } => r#"{"state":""}"#.into(),
            Effect::PublishHaDiscoveryZone { .. }
            | Effect::PublishHaDiscoveryTrv { .. } => "<discovery>".into(),
            Effect::PublishHaStateZone { state, .. }
            | Effect::PublishHaStateTrv { state, .. } => state.to_string(),
            Effect::PublishRaw { payload, .. } => payload.clone(),
        }
    }
}

fn zone_name(topology: &Topology, zone: ZoneIdx) -> String {
    topology
        .heating_config()
        .map(|cfg| cfg.zones[zone.as_usize()].name.clone())
        .unwrap_or_default()
}
