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
    /// physical labels like "label:1"). Provisioning ignores this; only
    /// kept around for diagnostics and Nix-side display.
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
            Self::MotionSensor { common, .. } => common,
        }
    }

    pub fn ieee_address(&self) -> &IeeeAddress {
        &self.common().ieee_address
    }

    pub fn options(&self) -> &BTreeMap<String, serde_json::Value> {
        &self.common().options
    }

    /// True for the kinds that can be put in a room's `devices` list as a
    /// runtime input (i.e. anything except plain `Light`). Useful for
    /// topology validation.
    pub fn is_runtime_input(&self) -> bool {
        !matches!(self, Self::Light(_))
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
