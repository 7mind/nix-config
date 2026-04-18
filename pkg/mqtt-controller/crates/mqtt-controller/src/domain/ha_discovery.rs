//! HA MQTT auto-discovery: derive controller state for TRVs and zones,
//! build discovery config payloads and topic strings.
//!
//! All functions are pure — no I/O, no MQTT. The heating logic
//! returns typed [`crate::domain::Effect`]s; the effect dispatcher
//! calls into this module to build the wire-level retained payloads.

use std::fmt;
use std::time::{Duration, Instant};

use serde_json::json;

use crate::entities::heating_zone::HeatingZoneEntity;
use crate::entities::trv::TrvEntity;

// ---------------------------------------------------------------------------
// TRV derived state
// ---------------------------------------------------------------------------

/// Controller-derived state for a TRV, exposed to Home Assistant.
/// Priority-ordered: the first matching condition wins.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrvDerivedState {
    Unknown,
    OpenWindow,
    PressureGroupOpen,
    PressureGroupRelease,
    MinCycleOpen,
    MinCycleRelease,
    Stale,
    HeatDemand,
    Idle,
}

impl TrvDerivedState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unknown => "UNKNOWN",
            Self::OpenWindow => "OPEN_WINDOW",
            Self::PressureGroupOpen => "PRESSURE_GROUP_OPEN",
            Self::PressureGroupRelease => "PRESSURE_GROUP_RELEASE",
            Self::MinCycleOpen => "MIN_CYCLE_OPEN",
            Self::MinCycleRelease => "MIN_CYCLE_RELEASE",
            Self::Stale => "STALE",
            Self::HeatDemand => "HEAT_DEMAND",
            Self::Idle => "IDLE",
        }
    }

    const ALL_OPTIONS: &[&str] = &[
        "UNKNOWN",
        "OPEN_WINDOW",
        "PRESSURE_GROUP_OPEN",
        "PRESSURE_GROUP_RELEASE",
        "MIN_CYCLE_OPEN",
        "MIN_CYCLE_RELEASE",
        "STALE",
        "HEAT_DEMAND",
        "IDLE",
    ];
}

impl fmt::Display for TrvDerivedState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

// ---------------------------------------------------------------------------
// Zone derived state
// ---------------------------------------------------------------------------

/// Controller-derived state for a heating zone (wall thermostat relay).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZoneDerivedState {
    Unknown,
    Stale,
    HeatDemand,
    MinRuntime,
    MinPause,
    Off,
}

impl ZoneDerivedState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unknown => "UNKNOWN",
            Self::Stale => "STALE",
            Self::HeatDemand => "HEAT_DEMAND",
            Self::MinRuntime => "MIN_RUNTIME",
            Self::MinPause => "MIN_PAUSE",
            Self::Off => "OFF",
        }
    }

    const ALL_OPTIONS: &[&str] = &[
        "UNKNOWN",
        "STALE",
        "HEAT_DEMAND",
        "MIN_RUNTIME",
        "MIN_PAUSE",
        "OFF",
    ];
}

impl fmt::Display for ZoneDerivedState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

// ---------------------------------------------------------------------------
// TASS-based state derivation
// ---------------------------------------------------------------------------

/// Derive TRV state from a TASS TrvEntity.
pub fn derive_trv_state_from_tass(
    trv: &TrvEntity,
    now: Instant,
    min_demand: u8,
    min_demand_fallback: u8,
) -> TrvDerivedState {
    if trv.last_seen.is_none() {
        return TrvDerivedState::Unknown;
    }
    if trv.is_inhibited(now) {
        return TrvDerivedState::OpenWindow;
    }
    use crate::entities::trv::{ForceOpenReason, TrvTarget};
    match trv.target.value() {
        Some(TrvTarget::ForcedOpen { reason: ForceOpenReason::PressureGroup }) => {
            return TrvDerivedState::PressureGroupOpen;
        }
        Some(TrvTarget::ForcedOpen { reason: ForceOpenReason::MinCycle }) => {
            return TrvDerivedState::MinCycleOpen;
        }
        _ => {}
    }
    // Release state: target changed from ForcedOpen to Setpoint but not yet confirmed.
    if trv.target.phase() == crate::tass::TargetPhase::Commanded {
        if let Some(reason) = trv.last_force_reason {
            return match reason {
                ForceOpenReason::PressureGroup => TrvDerivedState::PressureGroupRelease,
                ForceOpenReason::MinCycle => TrvDerivedState::MinCycleRelease,
            };
        }
    }
    if trv.is_stale(now) {
        return TrvDerivedState::Stale;
    }
    if trv.has_raw_demand(min_demand, min_demand_fallback) {
        return TrvDerivedState::HeatDemand;
    }
    TrvDerivedState::Idle
}

/// Derive zone state from TASS entities.
pub fn derive_zone_state_from_tass(
    zone: &HeatingZoneEntity,
    processor: &crate::logic::EventProcessor,
    now: Instant,
    min_demand: u8,
    min_demand_fallback: u8,
    min_pause_seconds: u64,
) -> ZoneDerivedState {
    if !zone.relay_state_known {
        return ZoneDerivedState::Unknown;
    }
    if zone.is_wt_stale(now) {
        return ZoneDerivedState::Stale;
    }
    if zone.is_relay_on() {
        // Check if any TRV in any zone has effective demand.
        // We need the zone's TRVs — find them from the heating config.
        let has_demand = processor.heating_config.as_ref()
            .and_then(|cfg| {
                cfg.zones.iter()
                    .find(|z| processor.world.heating_zones.get(&z.name).is_some_and(|hz| std::ptr::eq(hz, zone)))
                    .map(|z| z.trvs.iter().any(|zt| {
                        processor.world.trvs.get(&zt.device)
                            .is_some_and(|t| t.has_effective_demand(now, min_demand, min_demand_fallback))
                    }))
            })
            .unwrap_or(false);
        if has_demand {
            return ZoneDerivedState::HeatDemand;
        }
        return ZoneDerivedState::MinRuntime;
    }
    // Relay off — check for pump pause.
    if !processor.is_pump_running() {
        if let Some(off_since) = processor.effective_pump_off_since() {
            let elapsed = now.duration_since(off_since);
            if elapsed < Duration::from_secs(min_pause_seconds) {
                return ZoneDerivedState::MinPause;
            }
        }
    }
    ZoneDerivedState::Off
}

// ---------------------------------------------------------------------------
// HA discovery config and state update builders
// ---------------------------------------------------------------------------

fn sanitize_name(name: &str) -> String {
    name.replace('-', "_")
}

fn unique_id(entity_type: &str, name: &str) -> String {
    format!("mqtt_ctrl_{}_{}_state", entity_type, sanitize_name(name))
}

/// MQTT topic for publishing the entity's current state value.
pub fn state_topic(entity_type: &str, name: &str) -> String {
    format!("mqtt-controller/heating/{entity_type}/{name}/state")
}

/// HA discovery config topic for a heating entity.
pub fn discovery_topic(entity_type: &str, name: &str) -> String {
    format!(
        "homeassistant/sensor/{}/config",
        unique_id(entity_type, name)
    )
}

fn ha_device_block() -> serde_json::Value {
    json!({
        "identifiers": ["mqtt_controller_heating"],
        "name": "Heating Controller",
        "manufacturer": "mqtt-controller"
    })
}

fn display_name(device_name: &str) -> String {
    device_name
        .split('-')
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(c) => c.to_uppercase().to_string() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// One retained HA-discovery config publish: `(topic, payload)`.
/// Both fields are returned as owned strings so the caller can hand
/// them to the MQTT bridge without further allocation.
pub struct DiscoveryPublish {
    pub topic: String,
    pub payload: String,
}

/// Build the (topic, payload) pair for a retained HA discovery config.
/// `entity_type` is the topic segment ("trv" / "zone") and matches the
/// one used by `state_topic`. `kind_label` is the prefix shown in HA
/// ("TRV" / "Zone").
fn discovery_publish(
    entity_type: &str,
    kind_label: &str,
    name: &str,
    options: &[&str],
) -> DiscoveryPublish {
    let config = json!({
        "name": format!("{kind_label} {} State", display_name(name)),
        "state_topic": state_topic(entity_type, name),
        "unique_id": unique_id(entity_type, name),
        "device_class": "enum",
        "options": options,
        "device": ha_device_block(),
    });
    DiscoveryPublish {
        topic: discovery_topic(entity_type, name),
        payload: serde_json::to_string(&config).expect("JSON serialization"),
    }
}

/// Discovery-config publish for a TRV entity.
pub fn trv_discovery_publish(device_name: &str) -> DiscoveryPublish {
    discovery_publish("trv", "TRV", device_name, TrvDerivedState::ALL_OPTIONS)
}

/// Discovery-config publish for a zone entity.
pub fn zone_discovery_publish(zone_name: &str) -> DiscoveryPublish {
    discovery_publish("zone", "Zone", zone_name, ZoneDerivedState::ALL_OPTIONS)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
#[path = "ha_discovery_tests.rs"]
mod tests;
