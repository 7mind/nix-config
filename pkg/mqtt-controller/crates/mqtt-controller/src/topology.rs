//! Validated room topology. Built from a [`Config`] once at startup; the
//! rest of the system holds an `Arc<Topology>` and treats it as immutable.
//!
//! Responsibilities:
//!
//!   * **Validation:** every `parent` reference resolves; the parent
//!     graph is acyclic; every device referenced by a binding exists in the
//!     catalog and has a compatible kind; group ids and friendly_names
//!     are unique; member references point at known lights.
//!   * **Indexing:** the runtime hot path operates on positional
//!     indexes ([`RoomIdx`], [`DeviceIdx`], [`PlugIdx`], [`BindingIdx`])
//!     resolved once at build time, not on string lookups.
//!
//! Most validation logic mirrors the existing `defineRooms` validation in
//! `private/hosts/raspi5m/mqtt-controller-tools.nix`. The intent is for the
//! Nix layer to keep doing its own structural validation (so bugs surface
//! at build time) and for the Rust layer to **also** run its own as a
//! defense-in-depth check at startup. They should agree; disagreement is
//! a bug.

use std::collections::{BTreeMap, BTreeSet};

use crate::config::DeviceCatalogEntry;
use crate::config::catalog::PlugProtocol;
use crate::config::switch_model::{Gesture, SwitchModel};

mod build;
mod error;
mod index;
mod resolved;

pub use error::TopologyError;
pub use index::{BindingIdx, DeviceIdx, PlugIdx, RoomIdx, ZoneIdx};
pub use resolved::{ResolvedEffect, ResolvedTrigger};

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
    pub trigger: ResolvedTrigger,
    pub effect: ResolvedEffect,
}

/// Coarse classification of a [`DeviceCatalogEntry`] used by the
/// runtime's O(1) `is_plug` / `is_trv` predicates and topology
/// validation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeviceKind {
    Light,
    Switch,
    MotionSensor,
    Plug,
    Trv,
    WallThermostat,
}

impl DeviceKind {
    pub fn from_entry(entry: &DeviceCatalogEntry) -> Self {
        match entry {
            DeviceCatalogEntry::Light(_) => Self::Light,
            DeviceCatalogEntry::Switch { .. } => Self::Switch,
            DeviceCatalogEntry::MotionSensor { .. } => Self::MotionSensor,
            DeviceCatalogEntry::Plug { .. } => Self::Plug,
            DeviceCatalogEntry::Trv(_) => Self::Trv,
            DeviceCatalogEntry::WallThermostat(_) => Self::WallThermostat,
        }
    }

    /// Display label for error messages.
    pub fn label(self) -> &'static str {
        match self {
            Self::Light => "light",
            Self::Switch => "switch",
            Self::MotionSensor => "motion-sensor",
            Self::Plug => "plug",
            Self::Trv => "trv",
            Self::WallThermostat => "wall-thermostat",
        }
    }
}

/// Per-device metadata the runtime queries by [`DeviceIdx`].
#[derive(Debug, Clone)]
pub(in crate::topology) struct DeviceInfo {
    pub name: FriendlyName,
    pub kind: DeviceKind,
    /// `Some` for plugs (any protocol), `None` otherwise.
    pub plug_protocol: Option<PlugProtocol>,
    /// `Some` for switches, naming the model in `switch_models`.
    pub switch_model: Option<String>,
}

/// The validated topology. Owned as `Arc<Topology>` by the daemon.
/// Fields are visible within the topology module tree so that the
/// `build` submodule can construct the validated, indexed instance.
/// Outside callers use the accessor methods defined further below.
///
/// Storage is positional: rooms, devices, and bindings live in `Vec`s
/// and are referenced everywhere by typed indexes ([`RoomIdx`],
/// [`DeviceIdx`], [`PlugIdx`], [`BindingIdx`]). Boundary translation
/// from string names happens through the `*_idx` and `*_by_name`
/// accessors.
#[derive(Debug)]
pub struct Topology {
    // ---- Rooms ----------------------------------------------------------
    /// All resolved rooms in config order; index by [`RoomIdx`].
    pub(in crate::topology) rooms: Vec<ResolvedRoom>,
    /// `room.name` → [`RoomIdx`].
    pub(in crate::topology) room_by_name: BTreeMap<RoomName, RoomIdx>,
    /// `room.group_name` → [`RoomIdx`]. The controller uses this to
    /// route incoming `zigbee2mqtt/<group>` state events to the right
    /// room.
    pub(in crate::topology) room_by_group_name: BTreeMap<FriendlyName, RoomIdx>,
    /// Transitive descendants per room (with bindings only). Indexed by
    /// the parent's [`RoomIdx`].
    pub(in crate::topology) descendants_by_room: Vec<Vec<RoomIdx>>,
    /// Indexed by [`RoomIdx`]; `true` if any binding targets this room.
    /// Used by [`Topology::room_has_rules`] to gate descendant propagation.
    pub(in crate::topology) room_has_bindings: Vec<bool>,

    // ---- Devices --------------------------------------------------------
    /// Per-device metadata, indexed by [`DeviceIdx`]. Sorted by
    /// friendly_name so iteration order is deterministic.
    pub(in crate::topology) devices: Vec<DeviceInfo>,
    /// Friendly_name → [`DeviceIdx`]. Boundary translation only.
    pub(in crate::topology) device_by_name: BTreeMap<String, DeviceIdx>,

    // ---- Device-kind subsets (each entry is a [`DeviceIdx`]) ------------
    /// All switch device indexes. Used for MQTT subscriptions.
    pub(in crate::topology) switch_devices: Vec<DeviceIdx>,
    /// All motion sensor device indexes.
    pub(in crate::topology) motion_sensor_devices: Vec<DeviceIdx>,
    /// All plug device indexes (any protocol).
    pub(in crate::topology) plug_devices: Vec<DeviceIdx>,
    /// Subset of `plug_devices` with Zigbee protocol.
    pub(in crate::topology) zigbee_plug_devices: Vec<DeviceIdx>,
    /// Subset of `plug_devices` with Z-Wave protocol.
    pub(in crate::topology) zwave_plug_devices: Vec<DeviceIdx>,
    /// All TRV device indexes.
    pub(in crate::topology) trv_devices: Vec<DeviceIdx>,
    /// All wall thermostat device indexes.
    pub(in crate::topology) wall_thermostat_devices: Vec<DeviceIdx>,
    /// Z-Wave node_id → plug device index. Used by the provisioner.
    pub(in crate::topology) zwave_node_id_to_device: BTreeMap<u16, DeviceIdx>,

    // ---- Switch model details -------------------------------------------
    /// Switch model descriptors, keyed by model name. Stored so we can
    /// resolve raw z2m action strings to (button, gesture) pairs at
    /// parse time without needing the full Config.
    pub(in crate::topology) switch_models: BTreeMap<String, SwitchModel>,
    /// (device, button) pairs that have at least one soft_double_tap
    /// binding. The runtime uses this to activate the software
    /// double-tap detection window.
    pub(in crate::topology) soft_double_tap_buttons: BTreeSet<(DeviceIdx, String)>,
    /// (device, button) pairs from switch models that have both press
    /// and double_tap gestures mapped. The runtime uses this to
    /// activate the hardware double-tap suppression guard.
    pub(in crate::topology) hw_double_tap_buttons: BTreeSet<(DeviceIdx, String)>,

    // ---- Bindings -------------------------------------------------------
    /// Validated bindings, in config order. Index by [`BindingIdx`].
    pub(in crate::topology) bindings: Vec<ResolvedBinding>,
    /// (device, button, gesture) → binding indexes. The runtime
    /// dispatches each button event by looking up all matching
    /// bindings and executing them in order.
    pub(in crate::topology) button_binding_index:
        BTreeMap<(DeviceIdx, String, Gesture), Vec<BindingIdx>>,
    /// PowerBelow binding indexes, keyed by plug device.
    pub(in crate::topology) power_below_index: BTreeMap<DeviceIdx, Vec<BindingIdx>>,

    // ---- Motion routing -------------------------------------------------
    /// Motion sensor (device idx) → rooms it drives. Same shape as the
    /// old switch_index; production has each sensor in one room.
    pub(in crate::topology) motion_index: BTreeMap<DeviceIdx, Vec<RoomIdx>>,

    // ---- Heating --------------------------------------------------------
    /// Validated heating config (if present). Stored for the controller.
    pub(in crate::topology) heating_config: Option<crate::config::HeatingConfig>,
}

impl Topology {
    // ---- Rooms ----------------------------------------------------------

    /// All resolved rooms in config order.
    pub fn rooms(&self) -> impl Iterator<Item = &ResolvedRoom> {
        self.rooms.iter()
    }

    /// All resolved rooms with their indexes.
    pub fn rooms_with_idx(&self) -> impl Iterator<Item = (RoomIdx, &ResolvedRoom)> {
        self.rooms
            .iter()
            .enumerate()
            .map(|(i, r)| (RoomIdx::new(i as u32), r))
    }

    /// Direct positional access. Panics if `idx` is out of range — this
    /// indicates a stale index from a different topology.
    pub fn room(&self, idx: RoomIdx) -> &ResolvedRoom {
        &self.rooms[idx.as_usize()]
    }

    /// Look up a room by its internal name.
    pub fn room_by_name(&self, name: &str) -> Option<&ResolvedRoom> {
        self.room_idx(name).map(|i| self.room(i))
    }

    /// Look up the room owning a z2m group friendly_name.
    pub fn room_by_group_name(&self, group_name: &str) -> Option<&ResolvedRoom> {
        self.room_idx_by_group(group_name).map(|i| self.room(i))
    }

    /// Look up a room's index by name.
    pub fn room_idx(&self, name: &str) -> Option<RoomIdx> {
        self.room_by_name.get(name).copied()
    }

    /// Look up a room's index by its z2m group friendly_name.
    pub fn room_idx_by_group(&self, group_name: &str) -> Option<RoomIdx> {
        self.room_by_group_name.get(group_name).copied()
    }

    /// Rooms driven by a motion sensor (by name).
    pub fn rooms_for_motion(&self, sensor: &str) -> &[RoomIdx] {
        self.device_by_name
            .get(sensor)
            .and_then(|idx| self.motion_index.get(idx))
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// Rooms driven by a motion sensor (by device index).
    pub fn rooms_for_motion_idx(&self, sensor: DeviceIdx) -> &[RoomIdx] {
        self.motion_index
            .get(&sensor)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// Transitive descendants of `room` that have rules. Empty for leaf
    /// rooms or rooms whose only descendants are rule-less.
    pub fn descendants_of(&self, room: RoomIdx) -> &[RoomIdx] {
        self.descendants_by_room
            .get(room.as_usize())
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// True if the given room has runtime rules (bindings or motion sensors).
    pub fn room_has_rules(&self, room: RoomIdx) -> bool {
        let r = &self.rooms[room.as_usize()];
        !r.bound_motion.is_empty() || self.room_has_bindings[room.as_usize()]
    }

    /// All distinct group friendly names. Used by the daemon's startup
    /// state refresh to know which `zigbee2mqtt/<group>` topics to
    /// subscribe to.
    pub fn all_group_names(&self) -> Vec<&str> {
        self.rooms.iter().map(|r| r.group_name.as_str()).collect()
    }

    // ---- Devices --------------------------------------------------------

    /// Look up a device's index by name.
    pub fn device_idx(&self, name: &str) -> Option<DeviceIdx> {
        self.device_by_name.get(name).copied()
    }

    /// Friendly name of a device by index. Used to render MQTT topics.
    pub fn device_name(&self, idx: DeviceIdx) -> &str {
        &self.devices[idx.as_usize()].name
    }

    /// Coarse kind of a device.
    pub fn device_kind(&self, idx: DeviceIdx) -> DeviceKind {
        self.devices[idx.as_usize()].kind
    }

    /// True if the given device is a plug (any protocol).
    pub fn is_plug_idx(&self, idx: DeviceIdx) -> bool {
        self.device_kind(idx) == DeviceKind::Plug
    }

    /// Validate a `DeviceIdx` is a plug and return the typed `PlugIdx`.
    pub fn plug_idx(&self, idx: DeviceIdx) -> Option<PlugIdx> {
        if self.is_plug_idx(idx) {
            Some(PlugIdx::from_device(idx))
        } else {
            None
        }
    }

    /// Look up a plug by name.
    pub fn plug_idx_by_name(&self, name: &str) -> Option<PlugIdx> {
        self.device_idx(name).and_then(|d| self.plug_idx(d))
    }

    // ---- Switch device queries (by name, used at MQTT parse time) ------

    /// All switch device names from the catalog, in `DeviceIdx` order.
    /// Used for MQTT subscriptions to action topics.
    pub fn all_switch_device_names(&self) -> Vec<&str> {
        self.switch_devices
            .iter()
            .map(|&i| self.devices[i.as_usize()].name.as_str())
            .collect()
    }

    /// All distinct motion sensor friendly names.
    pub fn all_motion_sensor_names(&self) -> Vec<&str> {
        self.motion_sensor_devices
            .iter()
            .map(|&i| self.devices[i.as_usize()].name.as_str())
            .collect()
    }

    // ---- Bindings -------------------------------------------------------

    /// All resolved bindings.
    pub fn bindings(&self) -> &[ResolvedBinding] {
        &self.bindings
    }

    /// Lookup by index.
    pub fn binding(&self, idx: BindingIdx) -> &ResolvedBinding {
        &self.bindings[idx.as_usize()]
    }

    /// Binding indexes triggered by a (device, button, gesture) triple.
    pub fn bindings_for_button(
        &self,
        device: DeviceIdx,
        button: &str,
        gesture: Gesture,
    ) -> &[BindingIdx] {
        self.button_binding_index
            .get(&(device, button.to_string(), gesture))
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// Binding indexes with PowerBelow triggers for a plug device.
    pub fn bindings_for_power_below(&self, plug: DeviceIdx) -> &[BindingIdx] {
        self.power_below_index
            .get(&plug)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// True if this (device, button) pair has at least one soft_double_tap
    /// binding. Used by the runtime to activate the software double-tap
    /// detection window.
    pub fn is_soft_double_tap_button(&self, device: DeviceIdx, button: &str) -> bool {
        self.soft_double_tap_buttons
            .contains(&(device, button.to_string()))
    }

    /// True if this (device, button) pair comes from a model with hardware
    /// double-tap support. Used by the runtime to activate the double-tap
    /// suppression guard.
    pub fn is_hw_double_tap_button(&self, device: DeviceIdx, button: &str) -> bool {
        self.hw_double_tap_buttons
            .contains(&(device, button.to_string()))
    }

    /// The switch model name for a device, if it's a switch.
    pub fn switch_model_for(&self, device: DeviceIdx) -> Option<&str> {
        self.devices[device.as_usize()]
            .switch_model
            .as_deref()
    }

    /// Resolve a raw z2m action string for a switch device into a
    /// semantic `(button, gesture)` pair. Returns `None` if the device
    /// is not a known switch, has no model, or the action string is
    /// unrecognized.
    pub fn resolve_button_event(
        &self,
        device: &str,
        z2m_action: &str,
    ) -> Option<(DeviceIdx, String, Gesture)> {
        let dev_idx = self.device_idx(device)?;
        let model_name = self.devices[dev_idx.as_usize()].switch_model.as_ref()?;
        let model = self.switch_models.get(model_name)?;
        let mapping = model.resolve(z2m_action)?;
        Some((dev_idx, mapping.button.clone(), mapping.gesture))
    }

    // ---- Plug accessors -------------------------------------------------

    /// All plug device friendly names.
    pub fn all_plug_names(&self) -> Vec<&str> {
        self.plug_devices
            .iter()
            .map(|&i| self.devices[i.as_usize()].name.as_str())
            .collect()
    }

    /// All plug device indexes.
    pub fn all_plug_indexes(&self) -> &[DeviceIdx] {
        &self.plug_devices
    }

    /// True if this device name is a known plug (any protocol).
    pub fn is_plug(&self, device: &str) -> bool {
        self.device_idx(device)
            .map(|i| self.is_plug_idx(i))
            .unwrap_or(false)
    }

    /// True if this device is a Z-Wave plug.
    pub fn is_zwave_plug(&self, device: &str) -> bool {
        self.device_idx(device)
            .map(|i| self.is_zwave_plug_idx(i))
            .unwrap_or(false)
    }

    /// True if this device index is a Z-Wave plug.
    pub fn is_zwave_plug_idx(&self, idx: DeviceIdx) -> bool {
        self.devices[idx.as_usize()].plug_protocol == Some(PlugProtocol::Zwave)
    }

    /// Zigbee plug friendly names.
    pub fn zigbee_plug_names(&self) -> Vec<&str> {
        self.zigbee_plug_devices
            .iter()
            .map(|&i| self.devices[i.as_usize()].name.as_str())
            .collect()
    }

    /// Z-Wave plug friendly names.
    pub fn zwave_plug_names(&self) -> Vec<&str> {
        self.zwave_plug_devices
            .iter()
            .map(|&i| self.devices[i.as_usize()].name.as_str())
            .collect()
    }

    /// The protocol for a plug device (by name). Returns `None` if not a plug.
    pub fn plug_protocol(&self, device: &str) -> Option<PlugProtocol> {
        self.device_idx(device).and_then(|i| self.plug_protocol_idx(i))
    }

    /// The protocol for a plug device (by index).
    pub fn plug_protocol_idx(&self, idx: DeviceIdx) -> Option<PlugProtocol> {
        self.devices[idx.as_usize()].plug_protocol
    }

    /// Z-Wave node_id → plug name mapping. Used by the provisioner.
    pub fn zwave_node_id_to_name(&self) -> BTreeMap<u16, &str> {
        self.zwave_node_id_to_device
            .iter()
            .map(|(&id, &dev)| (id, self.devices[dev.as_usize()].name.as_str()))
            .collect()
    }

    // ---- TRV / wall thermostat -----------------------------------------

    /// All TRV device friendly names.
    pub fn all_trv_names(&self) -> Vec<&str> {
        self.trv_devices
            .iter()
            .map(|&i| self.devices[i.as_usize()].name.as_str())
            .collect()
    }

    /// True if `device` is a TRV.
    pub fn is_trv(&self, device: &str) -> bool {
        self.device_idx(device)
            .map(|i| self.device_kind(i) == DeviceKind::Trv)
            .unwrap_or(false)
    }

    /// True if `device` is a Light.
    pub fn is_light(&self, device: &str) -> bool {
        self.device_idx(device)
            .map(|i| self.device_kind(i) == DeviceKind::Light)
            .unwrap_or(false)
    }

    /// All wall thermostat device friendly names.
    pub fn all_wall_thermostat_names(&self) -> Vec<&str> {
        self.wall_thermostat_devices
            .iter()
            .map(|&i| self.devices[i.as_usize()].name.as_str())
            .collect()
    }

    /// True if `device` is a wall thermostat.
    pub fn is_wall_thermostat(&self, device: &str) -> bool {
        self.device_idx(device)
            .map(|i| self.device_kind(i) == DeviceKind::WallThermostat)
            .unwrap_or(false)
    }

    // ---- Heating --------------------------------------------------------

    /// The validated heating config, if present.
    pub fn heating_config(&self) -> Option<&crate::config::HeatingConfig> {
        self.heating_config.as_ref()
    }
}

#[cfg(test)]
mod tests;
