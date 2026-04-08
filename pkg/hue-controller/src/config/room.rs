//! Room schema. Each room is one zigbee group plus a binding of input
//! devices (switches, taps, motion sensors) to the room. Optionally has a
//! parent room (the ancestor whose state changes propagate to descendants
//! via the on/off invalidation we already worked out for bento).

use serde::{Deserialize, Serialize};

use super::scenes::SceneSchedule;

/// One room. Same shape as the entries in `defineRooms`'s `rooms` list,
/// after defaults have been resolved.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Room {
    /// Stable internal name. Used as the rule key, the topology lookup
    /// key, and the parent reference target.
    pub name: String,

    /// z2m group friendly_name. Defaults to `name` on the Nix side; we
    /// require it explicitly here so the Rust loader doesn't have to
    /// duplicate that defaulting logic.
    pub group_name: String,

    /// Numeric group id (1..=255). Used by the provisioner to drive
    /// `bridge/request/group/add` and to detect rename collisions.
    pub id: u8,

    /// Members of the z2m group, in `"<friendly_name>/<endpoint>"` form.
    /// The provisioner reconciles these against the live group's member
    /// list. Each entry must reference a `light` device in the catalog
    /// (validated at topology-build time).
    pub members: Vec<String>,

    /// Parent room name, if any. Pressing this room's parent triggers
    /// transitive descendant invalidation (see [`crate::topology`]).
    #[serde(default)]
    pub parent: Option<String>,

    /// Input devices bound to this room. Each entry is either a bare
    /// device name (for switches and motion sensors) or a `{device, button}`
    /// pair (for tap buttons). Heterogeneous types share one slot in the
    /// JSON; the topology builder partitions them by `DeviceKind`.
    #[serde(default)]
    pub devices: Vec<DeviceBinding>,

    /// Per-room scene schedule. Provisioning emits these as `scene_add`
    /// calls; the runtime reads `slots` for the cycle dispatch.
    pub scenes: SceneSchedule,

    /// Override of `defaults.room.off_transition_seconds`. Required at
    /// the room level (the Nix layer always renders it explicitly so the
    /// Rust loader doesn't need to duplicate the resolve-with-defaults
    /// logic).
    pub off_transition_seconds: f64,

    /// Override of `defaults.room.motion_off_cooldown_seconds`. Same
    /// "always rendered" reasoning.
    pub motion_off_cooldown_seconds: u32,
}

/// One input device binding inside a room. The Nix layer normalizes the
/// shorthand `"hue-s-foo"` form into a `{device: ..., button: null}`
/// record before rendering, so the Rust loader only ever sees the long
/// form. `button` is `Some(N)` for tap buttons and `None` for everything
/// else.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct DeviceBinding {
    pub device: String,

    #[serde(default)]
    pub button: Option<u8>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deserialize_minimal_room() {
        let json = r#"{
            "name": "kitchen-cooker",
            "group_name": "hue-lz-kitchen-cooker",
            "id": 15,
            "members": ["hue-l-cooker-bottom/11", "hue-l-cooker-top/11"],
            "parent": "kitchen-all",
            "devices": [
                {"device": "hue-ts-kitchen-entrance", "button": 2}
            ],
            "scenes": {
                "scenes": [
                    {"id": 1, "name": "x", "state": "ON", "brightness": null, "color_temp": null, "transition": 0.5}
                ],
                "slots": {
                    "day": {"start_hour": 0, "end_hour_exclusive": 24, "scene_ids": [1]}
                }
            },
            "off_transition_seconds": 0.8,
            "motion_off_cooldown_seconds": 0
        }"#;
        let room: Room = serde_json::from_str(json).unwrap();
        assert_eq!(room.name, "kitchen-cooker");
        assert_eq!(room.parent.as_deref(), Some("kitchen-all"));
        assert_eq!(room.devices.len(), 1);
        assert_eq!(room.devices[0].button, Some(2));
        assert_eq!(room.members.len(), 2);
    }

    #[test]
    fn switch_binding_has_no_button() {
        let json = r#"{
            "device": "hue-s-mid-bedroom"
        }"#;
        let b: DeviceBinding = serde_json::from_str(json).unwrap();
        assert_eq!(b.device, "hue-s-mid-bedroom");
        assert_eq!(b.button, None);
    }
}
