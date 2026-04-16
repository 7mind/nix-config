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
use crate::topology::{DeviceIdx, PlugIdx, RoomIdx, ZoneIdx};

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
    /// z2m to query and re-publish the device's current state.
    PublishDeviceGet { device: DeviceIdx },

    /// Publish a TRV-specific climate query (multi-attribute /get).
    PublishGetTrv { trv: DeviceIdx },

    /// Publish a Z-Wave value refresh request (writeValue read) for
    /// a Z-Wave plug.
    PublishZwaveRefresh { plug: PlugIdx },

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
            | Effect::PublishGetTrv { trv: device }
            | Effect::PublishHaDiscoveryTrv { trv: device }
            | Effect::PublishHaStateTrv { trv: device, .. } => Some(*device),
            Effect::PublishZwaveRefresh { plug } => Some(plug.device()),
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
}
