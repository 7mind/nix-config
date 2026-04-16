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
