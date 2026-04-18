//! Tests for `ha_discovery`. Split out so `ha_discovery.rs` stays focused on
//! production code. See `ha_discovery.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;
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
fn trv_discovery_config_topic_format() {
    let publish = trv_discovery_publish("bosch-trv-kitchen");
    assert_eq!(
        publish.topic,
        "homeassistant/sensor/mqtt_ctrl_trv_bosch_trv_kitchen_state/config"
    );
}

#[test]
fn trv_discovery_config_contains_options() {
    let publish = trv_discovery_publish("bosch-trv-kitchen");
    let v: serde_json::Value = serde_json::from_str(&publish.payload).unwrap();
    assert_eq!(v["device_class"], "enum");
    assert!(v["options"].as_array().unwrap().len() > 0);
    assert_eq!(v["state_topic"], "mqtt-controller/heating/trv/bosch-trv-kitchen/state");
}

#[test]
fn zone_discovery_config_topic_format() {
    let publish = zone_discovery_publish("master-bedroom");
    assert_eq!(
        publish.topic,
        "homeassistant/sensor/mqtt_ctrl_zone_master_bedroom_state/config"
    );
}

#[test]
fn state_topic_format() {
    assert_eq!(
        state_topic("trv", "bosch-trv-kitchen"),
        "mqtt-controller/heating/trv/bosch-trv-kitchen/state"
    );
}

#[test]
fn display_name_capitalizes_hyphen_words() {
    assert_eq!(display_name("bosch-trv-kitchen"), "Bosch Trv Kitchen");
    assert_eq!(display_name("master-bedroom"), "Master Bedroom");
}
