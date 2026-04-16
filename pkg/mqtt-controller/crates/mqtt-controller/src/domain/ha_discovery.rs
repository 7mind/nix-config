//! HA MQTT auto-discovery: derive controller state for TRVs and zones,
//! build discovery config and state update [`Action`]s.
//!
//! All functions are pure — no I/O, no MQTT. The heating logic
//! calls these from [`crate::logic::heating`]
//! and returns the resulting actions alongside its normal control actions.

use std::fmt;
use std::time::{Duration, Instant};

use serde_json::json;

use super::action::{Action, Payload};
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

fn discovery_config_topic(entity_type: &str, name: &str) -> String {
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

/// Build a retained HA discovery config Action.
///
/// `entity_type` is the topic segment ("trv" / "zone") and matches the
/// one used by `state_topic` / `state_update_action`. `kind_label`
/// is the prefix shown in HA ("TRV" / "Zone").
fn discovery_action(
    entity_type: &str,
    kind_label: &str,
    name: &str,
    options: &[&str],
) -> Action {
    let config = json!({
        "name": format!("{kind_label} {} State", display_name(name)),
        "state_topic": state_topic(entity_type, name),
        "unique_id": unique_id(entity_type, name),
        "device_class": "enum",
        "options": options,
        "device": ha_device_block(),
    });
    Action::raw(
        discovery_config_topic(entity_type, name),
        Payload::RawString(serde_json::to_string(&config).expect("JSON serialization")),
        true,
    )
}

/// Build the retained HA discovery config Action for a TRV entity.
pub fn trv_discovery_action(device_name: &str) -> Action {
    discovery_action("trv", "TRV", device_name, TrvDerivedState::ALL_OPTIONS)
}

/// Build the retained HA discovery config Action for a zone entity.
pub fn zone_discovery_action(zone_name: &str) -> Action {
    discovery_action("zone", "Zone", zone_name, ZoneDerivedState::ALL_OPTIONS)
}

/// Build a retained state update Action.
pub fn state_update_action(entity_type: &str, name: &str, state_str: &str) -> Action {
    Action::raw(
        state_topic(entity_type, name),
        Payload::RawString(state_str.to_string()),
        true,
    )
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::action::ActionTarget;
    use crate::entities::trv::{
        ForceOpenReason, HeatingRunningState, TrvActual, TrvEntity, TrvTarget,
    };
    use crate::tass::Owner;

    fn now() -> Instant {
        Instant::now()
    }

    // ---- TASS TRV state derivation ----

    #[test]
    fn tass_trv_unknown_when_never_seen() {
        let trv = TrvEntity::default();
        assert_eq!(derive_trv_state_from_tass(&trv, now(), 5, 80), TrvDerivedState::Unknown);
    }

    #[test]
    fn tass_trv_open_window_when_inhibited() {
        let n = now();
        let mut trv = TrvEntity::default();
        trv.last_seen = Some(n);
        trv.target.set_and_command(
            TrvTarget::Inhibited { until: n + Duration::from_secs(300) },
            Owner::Rule,
            n,
        );
        assert_eq!(derive_trv_state_from_tass(&trv, n, 5, 80), TrvDerivedState::OpenWindow);
    }

    #[test]
    fn tass_trv_pressure_group_open() {
        let n = now();
        let mut trv = TrvEntity::default();
        trv.last_seen = Some(n);
        trv.target.set_and_command(
            TrvTarget::ForcedOpen { reason: ForceOpenReason::PressureGroup },
            Owner::Rule,
            n,
        );
        assert_eq!(derive_trv_state_from_tass(&trv, n, 5, 80), TrvDerivedState::PressureGroupOpen);
    }

    #[test]
    fn tass_trv_pressure_group_release() {
        let n = now();
        let mut trv = TrvEntity::default();
        trv.last_seen = Some(n);
        // Simulate: was forced open for pressure group, now released to setpoint
        trv.last_force_reason = Some(ForceOpenReason::PressureGroup);
        trv.target.set_and_command(TrvTarget::Setpoint(21.0), Owner::Schedule, n);
        // Phase is Commanded (not yet confirmed)
        assert_eq!(derive_trv_state_from_tass(&trv, n, 5, 80), TrvDerivedState::PressureGroupRelease);
    }

    #[test]
    fn tass_trv_min_cycle_open() {
        let n = now();
        let mut trv = TrvEntity::default();
        trv.last_seen = Some(n);
        trv.target.set_and_command(
            TrvTarget::ForcedOpen { reason: ForceOpenReason::MinCycle },
            Owner::Rule,
            n,
        );
        assert_eq!(derive_trv_state_from_tass(&trv, n, 5, 80), TrvDerivedState::MinCycleOpen);
    }

    #[test]
    fn tass_trv_min_cycle_release() {
        let n = now();
        let mut trv = TrvEntity::default();
        trv.last_seen = Some(n);
        // Simulate: was forced open for min_cycle, now released to setpoint
        trv.last_force_reason = Some(ForceOpenReason::MinCycle);
        trv.target.set_and_command(TrvTarget::Setpoint(21.0), Owner::Schedule, n);
        assert_eq!(derive_trv_state_from_tass(&trv, n, 5, 80), TrvDerivedState::MinCycleRelease);
    }

    #[test]
    fn tass_trv_release_clears_after_confirm() {
        let n = now();
        let mut trv = TrvEntity::default();
        trv.last_seen = Some(n);
        trv.last_force_reason = Some(ForceOpenReason::PressureGroup);
        trv.target.set_and_command(TrvTarget::Setpoint(21.0), Owner::Schedule, n);
        trv.target.confirm(n);
        trv.last_force_reason = None; // cleared by heating logic on confirm
        assert_eq!(derive_trv_state_from_tass(&trv, n, 5, 80), TrvDerivedState::Idle);
    }

    #[test]
    fn tass_trv_stale() {
        let n = now();
        let mut trv = TrvEntity::default();
        trv.last_seen = Some(n - Duration::from_secs(31 * 60));
        assert_eq!(derive_trv_state_from_tass(&trv, n, 5, 80), TrvDerivedState::Stale);
    }

    #[test]
    fn tass_trv_heat_demand() {
        let n = now();
        let mut trv = TrvEntity::default();
        trv.last_seen = Some(n);
        let mut actual = TrvActual::default();
        actual.running_state = HeatingRunningState::Heat;
        actual.running_state_seen = true;
        actual.pi_heating_demand = Some(50);
        trv.actual.update(actual, n);
        assert_eq!(derive_trv_state_from_tass(&trv, n, 5, 80), TrvDerivedState::HeatDemand);
    }

    #[test]
    fn tass_trv_idle() {
        let n = now();
        let mut trv = TrvEntity::default();
        trv.last_seen = Some(n);
        assert_eq!(derive_trv_state_from_tass(&trv, n, 5, 80), TrvDerivedState::Idle);
    }

    // ---- Discovery config shape ----

    #[test]
    fn trv_discovery_config_is_retained() {
        let action = trv_discovery_action("bosch-trv-kitchen");
        assert!(matches!(action.target, ActionTarget::Raw { retain: true, .. }));
    }

    #[test]
    fn trv_discovery_config_topic_format() {
        let action = trv_discovery_action("bosch-trv-kitchen");
        assert_eq!(
            action.target_name(),
            "homeassistant/sensor/mqtt_ctrl_trv_bosch_trv_kitchen_state/config"
        );
    }

    #[test]
    fn trv_discovery_config_contains_options() {
        let action = trv_discovery_action("bosch-trv-kitchen");
        let json_str = match &action.payload {
            Payload::RawString(s) => s.clone(),
            _ => panic!("expected RawString"),
        };
        let v: serde_json::Value = serde_json::from_str(&json_str).unwrap();
        assert_eq!(v["device_class"], "enum");
        assert!(v["options"].as_array().unwrap().len() > 0);
        assert_eq!(v["state_topic"], "mqtt-controller/heating/trv/bosch-trv-kitchen/state");
    }

    #[test]
    fn zone_discovery_config_topic_format() {
        let action = zone_discovery_action("master-bedroom");
        assert_eq!(
            action.target_name(),
            "homeassistant/sensor/mqtt_ctrl_zone_master_bedroom_state/config"
        );
    }

    #[test]
    fn state_update_is_retained_bare_string() {
        let action = state_update_action("trv", "bosch-trv-kitchen", "HEAT_DEMAND");
        assert!(matches!(action.target, ActionTarget::Raw { retain: true, .. }));
        assert_eq!(
            action.target_name(),
            "mqtt-controller/heating/trv/bosch-trv-kitchen/state"
        );
        match &action.payload {
            Payload::RawString(s) => assert_eq!(s, "HEAT_DEMAND"),
            _ => panic!("expected RawString"),
        }
    }

    #[test]
    fn display_name_capitalizes_hyphen_words() {
        assert_eq!(display_name("bosch-trv-kitchen"), "Bosch Trv Kitchen");
        assert_eq!(display_name("master-bedroom"), "Master Bedroom");
    }
}
