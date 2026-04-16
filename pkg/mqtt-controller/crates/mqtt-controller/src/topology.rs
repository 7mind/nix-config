//! Validated room topology. Built from a [`Config`] once at startup; the
//! rest of the system holds an `Arc<Topology>` and treats it as immutable.
//!
//! Responsibilities:
//!
//!   * **Validation:** every `parent` reference resolves; the parent
//!     graph is acyclic; every device referenced by a binding exists in the
//!     catalog and has a compatible kind; group ids and friendly_names
//!     are unique; member references point at known lights.
//!   * **Indexing:** fast lookups for the runtime hot path:
//!       - room lookup by name
//!       - room lookup by group friendly_name (incoming z2m group state)
//!       - (device, button, gesture) → binding indexes (incoming switch events)
//!       - motion sensor → rooms (incoming motion events)
//!       - transitive descendants per room (filtered to those with rules)
//!
//! Most validation logic mirrors the existing `defineRooms` validation in
//! `private/hosts/raspi5m/mqtt-controller-tools.nix`. The intent is for the
//! Nix layer to keep doing its own structural validation (so bugs surface
//! at build time) and for the Rust layer to **also** run its own as a
//! defense-in-depth check at startup. They should agree; disagreement is
//! a bug.

use std::collections::{BTreeMap, BTreeSet};

use crate::config::catalog::PlugProtocol;
use crate::config::switch_model::{Gesture, SwitchModel};
use crate::config::{Effect, Trigger};

mod build;
mod error;
pub use error::TopologyError;

/// Stable name → resolved room data. Built from the raw `Config::rooms`
/// after validation; the controller indexes everything by room name.
pub type RoomName = String;

/// Friendly name of a switch, light, or motion sensor.
pub type FriendlyName = String;

/// One motion sensor → room binding. Carries the per-sensor settings the
/// controller needs at runtime (timeout, luminance gate). Lifted out of
/// the catalog so the controller doesn't have to keep doing catalog
/// lookups in the hot path.
#[derive(Debug, Clone)]
pub struct MotionBinding {
    pub sensor: FriendlyName,
    pub room: RoomName,
    pub occupancy_timeout_seconds: u32,
    pub max_illuminance: Option<u32>,
}

/// Validated, indexed view of one room. Holds everything the controller
/// needs at runtime — no follow-up catalog lookups required.
#[derive(Debug, Clone)]
pub struct ResolvedRoom {
    pub name: RoomName,
    pub group_name: FriendlyName,
    pub id: u8,
    pub members: Vec<String>,
    pub parent: Option<RoomName>,
    pub scenes: crate::config::SceneSchedule,
    pub off_transition_seconds: f64,
    pub motion_off_cooldown_seconds: u32,

    /// Motion sensors bound to this room. Empty if none.
    pub bound_motion: Vec<MotionBinding>,
}

impl ResolvedRoom {
    /// Quick check used by the runtime to gate motion-cooldown logic.
    pub fn has_motion_sensor(&self) -> bool {
        !self.bound_motion.is_empty()
    }
}

/// One resolved binding, ready for runtime dispatch.
#[derive(Debug, Clone)]
pub struct ResolvedBinding {
    pub name: String,
    pub trigger: Trigger,
    pub effect: Effect,
}

/// The validated topology. Owned as `Arc<Topology>` by the daemon.
/// Fields are visible within the topology module tree so that the
/// `build` submodule can construct the validated, indexed instance.
/// Outside callers use the accessor methods defined further below.
#[derive(Debug)]
pub struct Topology {
    pub(in crate::topology) rooms: BTreeMap<RoomName, ResolvedRoom>,
    /// group friendly_name → room name. The controller uses this to
    /// route incoming `zigbee2mqtt/<group>` state events to the right
    /// room.
    pub(in crate::topology) by_group_name: BTreeMap<FriendlyName, RoomName>,

    /// Motion sensor friendly_name → list of rooms it drives. Same shape
    /// as the old switch_index; production has each sensor in one room.
    pub(in crate::topology) motion_index: BTreeMap<FriendlyName, Vec<RoomName>>,

    /// Transitive descendants per room. Filtered to descendants that
    /// have rules — rule-less rooms have no per-zone state, so propagating
    /// "physically_on" to them would be pointless.
    pub(in crate::topology) descendants_by_room: BTreeMap<RoomName, Vec<RoomName>>,

    /// Validated bindings, in config order.
    pub(in crate::topology) bindings: Vec<ResolvedBinding>,

    /// (device, button, gesture) → binding indexes. The runtime dispatches
    /// each button event by looking up all matching bindings and executing
    /// them in order.
    pub(in crate::topology) button_binding_index: BTreeMap<(String, String, Gesture), Vec<usize>>,

    /// PowerBelow binding indexes, keyed by plug device name.
    pub(in crate::topology) power_below_index: BTreeMap<FriendlyName, Vec<usize>>,

    /// All switch device names from catalog. Used for MQTT subscriptions.
    pub(in crate::topology) switch_names: BTreeSet<FriendlyName>,

    /// (device, button) pairs that have at least one soft_double_tap
    /// binding. The runtime uses this to activate the software
    /// double-tap detection window.
    pub(in crate::topology) soft_double_tap_buttons: BTreeSet<(String, String)>,

    /// (device, button) pairs from switch models that have both press and
    /// double_tap gestures mapped. The runtime uses this to activate the
    /// hardware double-tap suppression guard.
    pub(in crate::topology) hw_double_tap_buttons: BTreeSet<(String, String)>,

    /// Rooms that have at least one binding targeting them. Used by
    /// `ResolvedRoom::has_rules()` (via the topology) to determine
    /// whether a room participates in descendant propagation.
    pub(in crate::topology) rooms_with_bindings: BTreeSet<RoomName>,

    /// Device name → switch model name mapping.
    pub(in crate::topology) device_models: BTreeMap<String, String>,

    /// Switch model descriptors, keyed by model name. Stored so we can
    /// resolve raw z2m action strings to (button, gesture) pairs at
    /// parse time without needing the full Config.
    pub(in crate::topology) switch_models: BTreeMap<String, SwitchModel>,

    /// All plug friendly_names from the device catalog.
    pub(in crate::topology) plug_names: BTreeSet<FriendlyName>,

    /// Zigbee plug friendly_names (subset of plug_names).
    pub(in crate::topology) zigbee_plug_names: BTreeSet<FriendlyName>,

    /// Z-Wave plug friendly_names (subset of plug_names).
    pub(in crate::topology) zwave_plug_names: BTreeSet<FriendlyName>,

    /// Per-plug protocol, keyed by friendly_name.
    pub(in crate::topology) plug_protocols: BTreeMap<FriendlyName, PlugProtocol>,

    /// Z-Wave node_id → plug friendly_name mapping. Used by the
    /// provisioner to map discovered nodes to their desired names.
    pub(in crate::topology) zwave_node_id_to_name: BTreeMap<u16, FriendlyName>,

    /// TRV device friendly_names from the device catalog.
    pub(in crate::topology) trv_names: BTreeSet<FriendlyName>,

    /// Wall thermostat device friendly_names from the device catalog.
    pub(in crate::topology) wall_thermostat_names: BTreeSet<FriendlyName>,

    /// Validated heating config (if present). Stored for the controller.
    pub(in crate::topology) heating_config: Option<crate::config::HeatingConfig>,
}

impl Topology {

    /// All resolved rooms, in stable name order.
    pub fn rooms(&self) -> impl Iterator<Item = &ResolvedRoom> {
        self.rooms.values()
    }

    /// Look up a room by its internal name.
    pub fn room_by_name(&self, name: &str) -> Option<&ResolvedRoom> {
        self.rooms.get(name)
    }

    /// Look up the room owning a z2m group friendly_name.
    pub fn room_by_group_name(&self, group_name: &str) -> Option<&ResolvedRoom> {
        self.by_group_name
            .get(group_name)
            .and_then(|n| self.rooms.get(n))
    }

    /// Rooms driven by a motion sensor friendly_name.
    pub fn rooms_for_motion(&self, sensor: &str) -> &[RoomName] {
        self.motion_index
            .get(sensor)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// Transitive descendants of `room` that have rules. Empty for leaf
    /// rooms or rooms whose only descendants are rule-less.
    pub fn descendants_of(&self, room: &str) -> &[RoomName] {
        self.descendants_by_room
            .get(room)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// All distinct group friendly names. Used by the daemon's startup
    /// state refresh to know which `zigbee2mqtt/<group>` topics to
    /// subscribe to.
    pub fn all_group_names(&self) -> Vec<&str> {
        self.rooms.values().map(|r| r.group_name.as_str()).collect()
    }

    /// All switch device names from the catalog. Used for MQTT
    /// subscriptions to action topics.
    pub fn all_switch_device_names(&self) -> &BTreeSet<FriendlyName> {
        &self.switch_names
    }

    /// All distinct motion sensor friendly names.
    pub fn all_motion_sensor_names(&self) -> BTreeSet<&str> {
        self.motion_index.keys().map(String::as_str).collect()
    }

    /// All resolved bindings.
    pub fn bindings(&self) -> &[ResolvedBinding] {
        &self.bindings
    }

    /// Binding indexes triggered by a (device, button, gesture) triple.
    pub fn bindings_for_button(&self, device: &str, button: &str, gesture: Gesture) -> &[usize] {
        self.button_binding_index
            .get(&(device.to_string(), button.to_string(), gesture))
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// Binding indexes with PowerBelow triggers for a plug device.
    pub fn bindings_for_power_below(&self, plug: &str) -> &[usize] {
        self.power_below_index
            .get(plug)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// True if this (device, button) pair has at least one soft_double_tap
    /// binding. Used by the runtime to activate the software double-tap
    /// detection window.
    pub fn is_soft_double_tap_button(&self, device: &str, button: &str) -> bool {
        self.soft_double_tap_buttons.contains(&(device.to_string(), button.to_string()))
    }

    /// True if this (device, button) pair comes from a model with hardware
    /// double-tap support. Used by the runtime to activate the double-tap
    /// suppression guard.
    pub fn is_hw_double_tap_button(&self, device: &str, button: &str) -> bool {
        self.hw_double_tap_buttons.contains(&(device.to_string(), button.to_string()))
    }

    /// The switch model name for a device, if it's a switch.
    pub fn switch_model_for(&self, device: &str) -> Option<&str> {
        self.device_models.get(device).map(String::as_str)
    }

    /// Resolve a raw z2m action string for a switch device into a
    /// semantic `(button, gesture)` pair. Returns `None` if the device
    /// is not a known switch, has no model, or the action string is
    /// unrecognized.
    pub fn resolve_button_event(&self, device: &str, z2m_action: &str) -> Option<(String, Gesture)> {
        let model_name = self.device_models.get(device)?;
        let model = self.switch_models.get(model_name)?;
        let mapping = model.resolve(z2m_action)?;
        Some((mapping.button.clone(), mapping.gesture))
    }

    /// True if the given room has runtime rules (bindings or motion sensors).
    pub fn room_has_rules(&self, room_name: &str) -> bool {
        let has_motion = self.rooms
            .get(room_name)
            .map(|r| !r.bound_motion.is_empty())
            .unwrap_or(false);
        has_motion || self.rooms_with_bindings.contains(room_name)
    }

    /// All plug device friendly names from the catalog.
    pub fn all_plug_names(&self) -> &BTreeSet<FriendlyName> {
        &self.plug_names
    }

    /// True if this device name is a known plug (any protocol).
    pub fn is_plug(&self, device: &str) -> bool {
        self.plug_names.contains(device)
    }

    /// True if this device is a Z-Wave plug.
    pub fn is_zwave_plug(&self, device: &str) -> bool {
        self.zwave_plug_names.contains(device)
    }

    /// Zigbee plug friendly_names.
    pub fn zigbee_plug_names(&self) -> &BTreeSet<FriendlyName> {
        &self.zigbee_plug_names
    }

    /// Z-Wave plug friendly_names.
    pub fn zwave_plug_names(&self) -> &BTreeSet<FriendlyName> {
        &self.zwave_plug_names
    }

    /// The protocol for a plug device. Returns `None` if the device
    /// is not a plug.
    pub fn plug_protocol(&self, device: &str) -> Option<PlugProtocol> {
        self.plug_protocols.get(device).copied()
    }

    /// Z-Wave node_id → plug name mapping. Used by the provisioner.
    pub fn zwave_node_id_to_name(&self) -> &BTreeMap<u16, FriendlyName> {
        &self.zwave_node_id_to_name
    }

    /// All TRV device friendly_names.
    pub fn all_trv_names(&self) -> &BTreeSet<FriendlyName> {
        &self.trv_names
    }

    /// True if `device` is a TRV.
    pub fn is_trv(&self, device: &str) -> bool {
        self.trv_names.contains(device)
    }

    /// All wall thermostat device friendly_names.
    pub fn all_wall_thermostat_names(&self) -> &BTreeSet<FriendlyName> {
        &self.wall_thermostat_names
    }

    /// True if `device` is a wall thermostat.
    pub fn is_wall_thermostat(&self, device: &str) -> bool {
        self.wall_thermostat_names.contains(device)
    }

    /// The validated heating config, if present.
    pub fn heating_config(&self) -> Option<&crate::config::HeatingConfig> {
        self.heating_config.as_ref()
    }
}



#[cfg(test)]
mod tests;
