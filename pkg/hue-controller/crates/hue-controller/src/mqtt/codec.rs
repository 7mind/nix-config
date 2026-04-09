//! z2m wire-format constants and helpers. Mostly here so the parser, the
//! provisioner, and any future telemetry consumer all agree on the
//! magic strings z2m sends.

/// Topic prefix that namespaces every z2m publication and command.
pub const Z2M_PREFIX: &str = "zigbee2mqtt/";

/// Bridge-control topics used by the provisioner. The daemon doesn't
/// touch these directly.
pub mod bridge {
    pub const GROUPS: &str = "zigbee2mqtt/bridge/groups";
    pub const DEVICES: &str = "zigbee2mqtt/bridge/devices";
    pub const RESPONSE_PREFIX: &str = "zigbee2mqtt/bridge/response/";
}
