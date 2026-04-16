//! Strongly typed indexes into the topology's vec-backed collections.
//!
//! Each newtype is a positional index that's only valid against the
//! [`super::Topology`] that produced it. The runtime uses these in
//! place of `String` lookups for room / device / plug / binding /
//! heating-zone references — the index is computed once at topology
//! build time and the runtime hot path becomes array indexing.
//!
//! `PlugIdx` carries its parent [`DeviceIdx`] so a known-plug can be
//! converted back to a generic device reference for free; the reverse
//! ([`super::Topology::plug_idx`]) is fallible.

use std::fmt;

macro_rules! define_idx {
    ($name:ident, $doc:expr) => {
        #[doc = $doc]
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
        pub struct $name(u32);

        impl $name {
            /// Construct from a raw `u32`. `build`-side use only;
            /// runtime callers should obtain indexes from topology
            /// accessors, never fabricate them.
            pub(in crate::topology) const fn new(v: u32) -> Self {
                Self(v)
            }

            /// Convert to `usize` for vec indexing.
            pub const fn as_usize(self) -> usize {
                self.0 as usize
            }

            /// Raw `u32` form — used only when serializing for the
            /// debug/wire layer.
            pub const fn raw(self) -> u32 {
                self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(f, "{}({})", stringify!($name), self.0)
            }
        }
    };
}

define_idx!(RoomIdx, "Index into `Topology::rooms`.");
define_idx!(DeviceIdx, "Index into `Topology::devices` (any device kind).");
define_idx!(BindingIdx, "Index into `Topology::bindings`.");
define_idx!(ZoneIdx, "Index into `HeatingConfig::zones`.");

/// Index of a device that has been validated as a plug. Carries the
/// parent [`DeviceIdx`] so it can be downgraded for free; the reverse
/// ([`super::Topology::plug_idx`]) is fallible.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PlugIdx(DeviceIdx);

impl PlugIdx {
    /// Construct from a `DeviceIdx`. `build`-side use only — caller
    /// is responsible for ensuring the device is a plug.
    pub(in crate::topology) const fn from_device(idx: DeviceIdx) -> Self {
        Self(idx)
    }

    /// Drop the plug-kind guarantee; returns the underlying device index.
    pub const fn device(self) -> DeviceIdx {
        self.0
    }

    /// Convert to `usize` for vec indexing.
    pub const fn as_usize(self) -> usize {
        self.0.as_usize()
    }
}

impl fmt::Display for PlugIdx {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "PlugIdx({})", self.0.raw())
    }
}
