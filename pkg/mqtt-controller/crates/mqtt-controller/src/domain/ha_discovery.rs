//! HA MQTT auto-discovery: derive controller state for TRVs and zones,
//! build discovery config and state update [`Action`]s.
//!
//! All functions are pure — no I/O, no MQTT. The heating controller
//! calls these from [`crate::controller::heating::HeatingController::handle_tick`]
//! and returns the resulting actions alongside its normal control actions.

use std::fmt;
use std::time::{Duration, Instant};

use serde_json::json;

use super::action::{Action, Payload};
use super::heating_state::{HeatingRuntimeState, HeatingZoneRuntimeState, TrvRuntimeState};

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

/// Derive the controller's view of a TRV's state from runtime flags.
pub fn derive_trv_state(
    trv: &TrvRuntimeState,
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
    if trv.pressure_forced {
        return TrvDerivedState::PressureGroupOpen;
    }
    if trv.pressure_release_pending {
        return TrvDerivedState::PressureGroupRelease;
    }
    if trv.min_cycle_forced {
        return TrvDerivedState::MinCycleOpen;
    }
    if trv.min_cycle_release_pending {
        return TrvDerivedState::MinCycleRelease;
    }
    if trv.is_stale(now) {
        return TrvDerivedState::Stale;
    }
    if trv.has_raw_demand(min_demand, min_demand_fallback) {
        return TrvDerivedState::HeatDemand;
    }
    TrvDerivedState::Idle
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

/// Derive the controller's view of a zone's state.
pub fn derive_zone_state(
    zone: &HeatingZoneRuntimeState,
    global: &HeatingRuntimeState,
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
    if zone.relay_on {
        if zone.has_effective_demand(now, min_demand, min_demand_fallback) {
            return ZoneDerivedState::HeatDemand;
        }
        return ZoneDerivedState::MinRuntime;
    }
    // Relay off — check for pump pause.
    if !global.is_pump_running() {
        if let Some(off_since) = global.effective_pump_off_since() {
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

/// Build the retained HA discovery config Action for a TRV entity.
pub fn trv_discovery_action(device_name: &str) -> Action {
    let config = json!({
        "name": format!("TRV {} State", display_name(device_name)),
        "state_topic": state_topic("trv", device_name),
        "unique_id": unique_id("trv", device_name),
        "device_class": "enum",
        "options": TrvDerivedState::ALL_OPTIONS,
        "device": ha_device_block(),
    });
    Action::raw(
        discovery_config_topic("trv", device_name),
        Payload::RawString(serde_json::to_string(&config).expect("JSON serialization")),
        true,
    )
}

/// Build the retained HA discovery config Action for a zone entity.
pub fn zone_discovery_action(zone_name: &str) -> Action {
    let config = json!({
        "name": format!("Zone {} State", display_name(zone_name)),
        "state_topic": state_topic("zone", zone_name),
        "unique_id": unique_id("zone", zone_name),
        "device_class": "enum",
        "options": ZoneDerivedState::ALL_OPTIONS,
        "device": ha_device_block(),
    });
    Action::raw(
        discovery_config_topic("zone", zone_name),
        Payload::RawString(serde_json::to_string(&config).expect("JSON serialization")),
        true,
    )
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
    use crate::domain::heating_state::{
        HeatingRunningState, HeatingRuntimeState, HeatingZoneRuntimeState, TrvRuntimeState,
    };

    fn now() -> Instant {
        Instant::now()
    }

    // ---- TRV state derivation ----

    #[test]
    fn trv_unknown_when_never_seen() {
        let trv = TrvRuntimeState::new();
        assert_eq!(derive_trv_state(&trv, now(), 5, 80), TrvDerivedState::Unknown);
    }

    #[test]
    fn trv_open_window_when_inhibited() {
        let n = now();
        let mut trv = TrvRuntimeState::new();
        trv.last_seen = Some(n);
        trv.inhibited_until = Some(n + Duration::from_secs(300));
        // Also set pressure_forced to verify priority
        trv.pressure_forced = true;
        assert_eq!(derive_trv_state(&trv, n, 5, 80), TrvDerivedState::OpenWindow);
    }

    #[test]
    fn trv_pressure_group_open() {
        let n = now();
        let mut trv = TrvRuntimeState::new();
        trv.last_seen = Some(n);
        trv.pressure_forced = true;
        assert_eq!(derive_trv_state(&trv, n, 5, 80), TrvDerivedState::PressureGroupOpen);
    }

    #[test]
    fn trv_pressure_group_release() {
        let n = now();
        let mut trv = TrvRuntimeState::new();
        trv.last_seen = Some(n);
        trv.pressure_release_pending = true;
        assert_eq!(derive_trv_state(&trv, n, 5, 80), TrvDerivedState::PressureGroupRelease);
    }

    #[test]
    fn trv_min_cycle_open() {
        let n = now();
        let mut trv = TrvRuntimeState::new();
        trv.last_seen = Some(n);
        trv.min_cycle_forced = true;
        assert_eq!(derive_trv_state(&trv, n, 5, 80), TrvDerivedState::MinCycleOpen);
    }

    #[test]
    fn trv_min_cycle_release() {
        let n = now();
        let mut trv = TrvRuntimeState::new();
        trv.last_seen = Some(n);
        trv.min_cycle_release_pending = true;
        assert_eq!(derive_trv_state(&trv, n, 5, 80), TrvDerivedState::MinCycleRelease);
    }

    #[test]
    fn trv_stale() {
        let n = now();
        let mut trv = TrvRuntimeState::new();
        trv.last_seen = Some(n - Duration::from_secs(31 * 60));
        assert_eq!(derive_trv_state(&trv, n, 5, 80), TrvDerivedState::Stale);
    }

    #[test]
    fn trv_heat_demand() {
        let n = now();
        let mut trv = TrvRuntimeState::new();
        trv.last_seen = Some(n);
        trv.running_state = HeatingRunningState::Heat;
        trv.running_state_seen = true;
        trv.pi_heating_demand = Some(50);
        assert_eq!(derive_trv_state(&trv, n, 5, 80), TrvDerivedState::HeatDemand);
    }

    #[test]
    fn trv_idle() {
        let n = now();
        let mut trv = TrvRuntimeState::new();
        trv.last_seen = Some(n);
        assert_eq!(derive_trv_state(&trv, n, 5, 80), TrvDerivedState::Idle);
    }

    // ---- Zone state derivation ----

    #[test]
    fn zone_unknown_when_state_not_known() {
        let zone = HeatingZoneRuntimeState::new();
        let global = HeatingRuntimeState::new();
        assert_eq!(
            derive_zone_state(&zone, &global, now(), 5, 80, 180),
            ZoneDerivedState::Unknown
        );
    }

    #[test]
    fn zone_stale() {
        let n = now();
        let mut zone = HeatingZoneRuntimeState::new();
        zone.relay_state_known = true;
        zone.wt_last_seen = Some(n - Duration::from_secs(11 * 60));
        let global = HeatingRuntimeState::new();
        assert_eq!(
            derive_zone_state(&zone, &global, n, 5, 80, 180),
            ZoneDerivedState::Stale
        );
    }

    #[test]
    fn zone_heat_demand() {
        let n = now();
        let mut zone = HeatingZoneRuntimeState::new();
        zone.relay_state_known = true;
        zone.relay_on = true;
        let mut trv = TrvRuntimeState::new();
        trv.last_seen = Some(n);
        trv.running_state = HeatingRunningState::Heat;
        trv.running_state_seen = true;
        trv.pi_heating_demand = Some(50);
        zone.trvs.insert("t1".into(), trv);
        let global = HeatingRuntimeState::new();
        assert_eq!(
            derive_zone_state(&zone, &global, n, 5, 80, 180),
            ZoneDerivedState::HeatDemand
        );
    }

    #[test]
    fn zone_min_runtime() {
        let n = now();
        let mut zone = HeatingZoneRuntimeState::new();
        zone.relay_state_known = true;
        zone.relay_on = true;
        // No demanding TRVs → MIN_RUNTIME
        let global = HeatingRuntimeState::new();
        assert_eq!(
            derive_zone_state(&zone, &global, n, 5, 80, 180),
            ZoneDerivedState::MinRuntime
        );
    }

    #[test]
    fn zone_min_pause() {
        let n = now();
        let mut zone = HeatingZoneRuntimeState::new();
        zone.relay_state_known = true;
        zone.relay_on = false;
        let mut global = HeatingRuntimeState::new();
        global.pump_off_since = Some(n - Duration::from_secs(60));
        assert_eq!(
            derive_zone_state(&zone, &global, n, 5, 80, 180),
            ZoneDerivedState::MinPause
        );
    }

    #[test]
    fn zone_off() {
        let n = now();
        let mut zone = HeatingZoneRuntimeState::new();
        zone.relay_state_known = true;
        zone.relay_on = false;
        let global = HeatingRuntimeState::new();
        assert_eq!(
            derive_zone_state(&zone, &global, n, 5, 80, 180),
            ZoneDerivedState::Off
        );
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
