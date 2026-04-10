//! Device catalog. Each entry is keyed by friendly_name in the parent
//! config and carries:
//!
//!   * its **kind** (light / switch / tap / motion sensor) — used by both
//!     the runtime topology builder (rooms only accept matching device
//!     kinds in their `devices` slot) and the provisioner (motion sensor
//!     options get written to the device).
//!   * any **per-device options** to write at provision time (sensitivity,
//!     LED indication, occupancy timeout — these hit the device's NVS via
//!     z2m's `/set` topic).
//!
//! The kind tag mirrors the friendly-name prefix convention used in
//! `hue-lights-tools.nix`:
//!
//!   * `hue-l-*`  → light
//!   * `hue-s-*`  → switch (Hue dimmer)
//!   * `hue-ts-*` → tap switch (Hue Tap)
//!   * `hue-ms-*` → motion sensor
//!
//! Internal representation note: this is one big internally-tagged enum
//! with the common fields duplicated across every variant rather than a
//! struct with a flattened kind. The reason is that serde's
//! `#[serde(flatten)]` doesn't compose with `#[serde(deny_unknown_fields)]`
//! — and we want to reject unknown fields in the JSON so typos surface as
//! parse errors instead of silent drops. The tiny duplication is worth
//! the safety.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Newtype around a hex-encoded zigbee IEEE address (`0x00178801086a51d2`).
/// Kept as `String` rather than `u64` because that's what z2m sends on the
/// wire and printing/comparing it as a string is the common case.
pub type IeeeAddress = String;

/// Which MQTT bridge a plug communicates through.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, Default, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum PlugProtocol {
    /// zigbee2mqtt — single state topic with JSON `{"state":"ON","power":…}`.
    #[default]
    Zigbee,
    /// Z-Wave JS UI — separate topics per command class
    /// (`switch_binary/endpoint_0/currentValue`,
    /// `meter/endpoint_0/value/66049`).
    Zwave,
}

/// One catalog entry. Tagged by `kind`. Variant data carries everything
/// needed by the provisioner and the runtime — no follow-up lookups.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case", deny_unknown_fields)]
pub enum DeviceCatalogEntry {
    /// Bulb. Has no runtime behaviour of its own — appears only in a
    /// room's `members` list. Carried in the catalog so we can validate
    /// every member reference points at a real device.
    Light(CommonFields),

    /// Hue dimmer wall switch. Press handlers: on/off + brightness up/down.
    Switch(CommonFields),

    /// Hue Tap. Each of the 4 buttons can bind to a (possibly different)
    /// room. The catalog entry has no per-button state; the room's
    /// `devices` list carries the (device, button) pair.
    Tap(CommonFields),

    /// Hue motion sensor. Per-sensor options get written by the
    /// provisioner; the runtime needs the timeout (for the auto-off
    /// cooldown gate) and the max illuminance (luminance gate on motion-on).
    #[serde(rename = "motion-sensor")]
    MotionSensor {
        #[serde(flatten)]
        common: CommonFields,
        /// How many seconds of "no motion" before the runtime is allowed
        /// to fire its motion-off handler. Defaults to 60 in production.
        #[serde(default = "default_occupancy_timeout")]
        occupancy_timeout_seconds: u32,

        /// Max illuminance (in lux) at which motion-on is still allowed
        /// to fire. Above this threshold the room is "bright enough" and
        /// motion is suppressed. `None` disables the gate entirely.
        #[serde(default)]
        max_illuminance: Option<u32>,
    },

    /// Smart plug (Zigbee or Z-Wave). Controlled via action rules rather
    /// than room scene cycling. The `variant` tag identifies the hardware
    /// model, and `capabilities` lists what the bridge exposes (derived
    /// from the variant on the Nix side).
    Plug {
        #[serde(flatten)]
        common: CommonFields,
        /// Hardware variant identifier (e.g. "sonoff-power",
        /// "neo-nas-wr01ze"). Used for documentation and to gate
        /// capability-dependent action triggers at config validation time.
        variant: String,
        /// Capabilities this plug exposes, derived from `variant` on the
        /// Nix side. The Rust topology validator uses this to reject
        /// `power_below` triggers on plugs that lack `"power"`.
        capabilities: Vec<String>,
        /// Which MQTT bridge protocol this plug uses. Defaults to
        /// `zigbee` for backward compatibility.
        #[serde(default)]
        protocol: PlugProtocol,
        /// Z-Wave node ID. Required when `protocol` is `zwave`; ignored
        /// for zigbee plugs. This is the stable identifier within the
        /// Z-Wave network (assigned at inclusion, does not change).
        #[serde(default)]
        node_id: Option<u16>,
    },
}

/// Fields every device catalog entry carries, regardless of kind. Lifted
/// into a struct so the variants don't have to repeat them by name.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CommonFields {
    /// IEEE address — needed by the provisioner so it can issue
    /// `bridge/request/device/rename` against a stable identifier instead
    /// of a possibly-stale current friendly name.
    pub ieee_address: IeeeAddress,

    /// Optional human-readable description (currently used for taps with
    /// physical labels like "label:1"). Written to z2m via
    /// `bridge/request/device/options` during provisioning.
    #[serde(default)]
    pub description: Option<String>,

    /// Per-device options the provisioner writes via `<friendly_name>/set`
    /// after dedup-checking against the device's retained state. Same shape
    /// as the old `hue-setup` config — opaque key/value JSON the provisioner
    /// passes through unchanged.
    #[serde(default)]
    pub options: BTreeMap<String, serde_json::Value>,
}

fn default_occupancy_timeout() -> u32 {
    60
}

impl DeviceCatalogEntry {
    pub fn common(&self) -> &CommonFields {
        match self {
            Self::Light(c) | Self::Switch(c) | Self::Tap(c) => c,
            Self::MotionSensor { common, .. } | Self::Plug { common, .. } => common,
        }
    }

    pub fn ieee_address(&self) -> &IeeeAddress {
        &self.common().ieee_address
    }

    pub fn description(&self) -> Option<&str> {
        self.common().description.as_deref()
    }

    pub fn options(&self) -> &BTreeMap<String, serde_json::Value> {
        &self.common().options
    }

    /// True for the kinds that can be put in a room's `devices` list as a
    /// runtime input (i.e. switches, taps, and motion sensors — not lights
    /// or plugs). Useful for topology validation.
    pub fn is_runtime_input(&self) -> bool {
        !matches!(self, Self::Light(_) | Self::Plug { .. })
    }

    /// True if this kind is a Hue Tap.
    pub fn is_tap(&self) -> bool {
        matches!(self, Self::Tap(_))
    }

    /// True if this kind is a wall switch (Hue dimmer).
    pub fn is_switch(&self) -> bool {
        matches!(self, Self::Switch(_))
    }

    /// True if this kind is a motion sensor.
    pub fn is_motion_sensor(&self) -> bool {
        matches!(self, Self::MotionSensor { .. })
    }

    /// True if this kind is a smart plug (any protocol).
    pub fn is_plug(&self) -> bool {
        matches!(self, Self::Plug { .. })
    }

    /// True if this is a Z-Wave plug.
    pub fn is_zwave_plug(&self) -> bool {
        matches!(self, Self::Plug { protocol: PlugProtocol::Zwave, .. })
    }

    /// The plug's MQTT protocol, if this is a plug.
    pub fn plug_protocol(&self) -> Option<PlugProtocol> {
        match self {
            Self::Plug { protocol, .. } => Some(*protocol),
            _ => None,
        }
    }

    /// The Z-Wave node ID, if this is a Z-Wave plug.
    pub fn zwave_node_id(&self) -> Option<u16> {
        match self {
            Self::Plug { protocol: PlugProtocol::Zwave, node_id, .. } => *node_id,
            _ => None,
        }
    }

    /// True if this plug has the named capability (e.g. "power").
    /// Returns false for non-plug devices.
    pub fn has_capability(&self, cap: &str) -> bool {
        match self {
            Self::Plug { capabilities, .. } => capabilities.iter().any(|c| c == cap),
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deserialize_motion_sensor_with_defaults() {
        let json = r#"{
            "kind": "motion-sensor",
            "ieee_address": "0xaa"
        }"#;
        let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
        match entry {
            DeviceCatalogEntry::MotionSensor {
                occupancy_timeout_seconds,
                max_illuminance,
                ..
            } => {
                assert_eq!(occupancy_timeout_seconds, 60);
                assert_eq!(max_illuminance, None);
            }
            other => panic!("expected MotionSensor, got {other:?}"),
        }
    }

    #[test]
    fn deserialize_motion_sensor_with_overrides() {
        let json = r#"{
            "kind": "motion-sensor",
            "ieee_address": "0xaa",
            "occupancy_timeout_seconds": 180,
            "max_illuminance": 25
        }"#;
        let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
        match entry {
            DeviceCatalogEntry::MotionSensor {
                occupancy_timeout_seconds,
                max_illuminance,
                ..
            } => {
                assert_eq!(occupancy_timeout_seconds, 180);
                assert_eq!(max_illuminance, Some(25));
            }
            other => panic!("expected MotionSensor, got {other:?}"),
        }
    }

    #[test]
    fn deserialize_each_kind() {
        for (json, expected_predicate) in [
            (
                r#"{"kind":"light","ieee_address":"0x1"}"#,
                DeviceCatalogEntry::is_runtime_input as fn(&DeviceCatalogEntry) -> bool,
            ),
            (
                r#"{"kind":"switch","ieee_address":"0x2"}"#,
                DeviceCatalogEntry::is_switch,
            ),
            (
                r#"{"kind":"tap","ieee_address":"0x3"}"#,
                DeviceCatalogEntry::is_tap,
            ),
        ] {
            let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
            // Light should NOT match is_runtime_input; the others should
            // match their respective predicates.
            if json.contains("\"light\"") {
                assert!(!entry.is_runtime_input());
            } else {
                assert!(expected_predicate(&entry), "predicate failed for {json}");
            }
        }
    }

    #[test]
    fn options_carry_arbitrary_json() {
        let json = r#"{
            "kind": "motion-sensor",
            "ieee_address": "0xaa",
            "options": {
                "occupancy_timeout": 60,
                "motion_sensitivity": "high",
                "led_indication": false
            }
        }"#;
        let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
        let opts = entry.options();
        assert_eq!(opts.len(), 3);
        assert_eq!(opts.get("motion_sensitivity").unwrap(), &serde_json::json!("high"));
    }

    #[test]
    fn unknown_field_is_rejected() {
        let json = r#"{
            "kind": "switch",
            "ieee_address": "0x2",
            "ghost_field": 42
        }"#;
        let result: Result<DeviceCatalogEntry, _> = serde_json::from_str(json);
        assert!(
            result.is_err(),
            "deny_unknown_fields should reject ghost_field"
        );
    }

    #[test]
    fn deserialize_plug_with_capabilities() {
        let json = r#"{
            "kind": "plug",
            "ieee_address": "0xbb",
            "variant": "sonoff-power",
            "capabilities": ["on-off", "power", "energy"]
        }"#;
        let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
        assert!(entry.is_plug());
        assert!(!entry.is_zwave_plug());
        assert_eq!(entry.plug_protocol(), Some(PlugProtocol::Zigbee));
        assert!(entry.has_capability("power"));
        assert!(entry.has_capability("on-off"));
        assert!(!entry.has_capability("voltage"));
        match entry {
            DeviceCatalogEntry::Plug { variant, capabilities, protocol, node_id, .. } => {
                assert_eq!(variant, "sonoff-power");
                assert_eq!(capabilities, vec!["on-off", "power", "energy"]);
                assert_eq!(protocol, PlugProtocol::Zigbee);
                assert_eq!(node_id, None);
            }
            other => panic!("expected Plug, got {other:?}"),
        }
    }

    #[test]
    fn deserialize_plug_basic_no_power() {
        let json = r#"{
            "kind": "plug",
            "ieee_address": "0xcc",
            "variant": "sonoff-basic",
            "capabilities": ["on-off"]
        }"#;
        let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
        assert!(entry.is_plug());
        assert!(!entry.has_capability("power"));
    }

    #[test]
    fn plug_is_not_runtime_input() {
        let json = r#"{
            "kind": "plug",
            "ieee_address": "0xdd",
            "variant": "sonoff-power",
            "capabilities": ["on-off", "power"]
        }"#;
        let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
        assert!(!entry.is_runtime_input());
    }

    #[test]
    fn deserialize_zwave_plug() {
        let json = r#"{
            "kind": "plug",
            "ieee_address": "zwave:6",
            "variant": "neo-nas-wr01ze",
            "capabilities": ["on-off", "power"],
            "protocol": "zwave",
            "node_id": 6
        }"#;
        let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
        assert!(entry.is_plug());
        assert!(entry.is_zwave_plug());
        assert_eq!(entry.plug_protocol(), Some(PlugProtocol::Zwave));
        assert_eq!(entry.zwave_node_id(), Some(6));
        assert!(entry.has_capability("power"));
    }

    #[test]
    fn zwave_plug_without_node_id() {
        let json = r#"{
            "kind": "plug",
            "ieee_address": "zwave:?",
            "variant": "neo-nas-wr01ze",
            "capabilities": ["on-off"],
            "protocol": "zwave"
        }"#;
        let entry: DeviceCatalogEntry = serde_json::from_str(json).unwrap();
        assert!(entry.is_zwave_plug());
        assert_eq!(entry.zwave_node_id(), None);
    }

    #[test]
    fn classifier_helpers() {
        let switch = DeviceCatalogEntry::Switch(CommonFields {
            ieee_address: "0x1".into(),
            description: None,
            options: BTreeMap::new(),
        });
        assert!(switch.is_runtime_input());
        assert!(switch.is_switch());

        let light = DeviceCatalogEntry::Light(CommonFields {
            ieee_address: "0x2".into(),
            description: None,
            options: BTreeMap::new(),
        });
        assert!(!light.is_runtime_input());

        let ms = DeviceCatalogEntry::MotionSensor {
            common: CommonFields {
                ieee_address: "0x3".into(),
                description: None,
                options: BTreeMap::new(),
            },
            occupancy_timeout_seconds: 60,
            max_illuminance: None,
        };
        assert!(ms.is_motion_sensor());
        assert!(ms.is_runtime_input());
    }
}
