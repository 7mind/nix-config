//! Room schema. Each room is one zigbee group with motion sensors.
//! Switch/tap bindings are now in the top-level `bindings` array,
//! not in the room itself. Optionally has a parent room (the ancestor
//! whose state changes propagate to descendants via on/off invalidation).

use serde::{Deserialize, Serialize};

use super::scenes::SceneSchedule;

/// How motion events drive this room's lights.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum MotionMode {
    /// Full automation: motion-on turns lights on (motion-owned), motion-off
    /// turns them off. The historical default.
    #[default]
    OnOff,
    /// Motion-on turns lights on (user-owned, i.e. ownership does NOT
    /// transfer to motion). Motion-off never fires — lights stay on until
    /// explicitly turned off.
    OnOnly,
    /// Motion-on claims motion ownership but does NOT turn lights on.
    /// Motion-off turns lights off if they are currently on. A user/web
    /// press while the zone is motion-owned preserves that ownership, so
    /// manual control cannot defeat the automatic off.
    OffOnly,
}

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

    /// Motion sensors bound to this room. Each entry is a device
    /// friendly_name referencing a `motion-sensor` in the catalog.
    #[serde(default)]
    pub motion_sensors: Vec<String>,

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

    /// How motion events drive this room's lights. See [`MotionMode`].
    /// Defaults to `on-off` when omitted so pre-existing configs keep
    /// behaving identically. The Nix layer always renders it explicitly.
    #[serde(default)]
    pub motion_mode: MotionMode,
}

#[cfg(test)]
#[path = "room_tests.rs"]
mod tests;
