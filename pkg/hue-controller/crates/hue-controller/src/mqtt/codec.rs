//! z2m wire-format constants and helpers. Mostly here so the parser, the
//! provisioner, and any future telemetry consumer all agree on the
//! magic strings z2m sends.

/// Topic prefix that namespaces every z2m publication and command.
pub const Z2M_PREFIX: &str = "zigbee2mqtt/";

/// Topic prefix for Z-Wave JS UI publications.
pub const ZWAVE_PREFIX: &str = "zwave/";

/// Bridge-control topics used by the provisioner. The daemon doesn't
/// touch these directly.
pub mod bridge {
    pub const GROUPS: &str = "zigbee2mqtt/bridge/groups";
    pub const DEVICES: &str = "zigbee2mqtt/bridge/devices";
    pub const RESPONSE_PREFIX: &str = "zigbee2mqtt/bridge/response/";
}

/// Z-Wave JS UI MQTT API topics used by the provisioner for rename
/// and attribute operations.
pub mod zwave_api {
    /// Gateway client prefix. The gateway name ("zwave") is configured
    /// in `modules/nixos/zwave.nix` → `mqttSettings.name`.
    pub const GATEWAY_PREFIX: &str = "zwave/_CLIENTS/ZWAVE_GATEWAY-zwave/api/";
}

/// Z-Wave meter value property keys (command class 50).
pub mod zwave_meter {
    /// Electric consumption in kWh (scale 0, rate type 1).
    pub const ENERGY_KWH: u32 = 65537;
    /// Electric consumption in Watts (scale 2, rate type 1).
    pub const POWER_W: u32 = 66049;
    /// Electric consumption in Volts (scale 4, rate type 1).
    pub const VOLTAGE_V: u32 = 66561;
    /// Electric consumption in Amps (scale 5, rate type 1).
    pub const CURRENT_A: u32 = 66817;
}
