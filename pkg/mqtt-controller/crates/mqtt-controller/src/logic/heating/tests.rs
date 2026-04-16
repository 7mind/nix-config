use super::*;
use crate::config::heating::*;
use crate::config::{CommonFields, Config, Defaults, DeviceCatalogEntry};
use crate::entities::heating_zone::HeatingZoneActual;
use crate::logic::EventProcessor;
use crate::time::{Clock, FakeClock};
use crate::topology::Topology;
use std::collections::BTreeMap;
use std::sync::Arc;

/// Bridges Effect's `topic`/`payload_string` methods to the friendly-name
/// shape the heating tests have always used. `target_name(&ep)` returns
/// the friendly name for `/set` publishes so
/// `.filter(|a| a.target_name(&ep) == "trv-bath-1")` keeps reading
/// naturally. HA-targeted effects fall back to the full topic, so
/// friendly-name filters never accidentally match them.
trait EffectTestExt {
    fn target_name(&self, ep: &EventProcessor) -> String;
    fn payload_json(&self, ep: &EventProcessor) -> String;
}

impl EffectTestExt for Effect {
    fn target_name(&self, ep: &EventProcessor) -> String {
        let topo = ep.topology();
        match self {
            Effect::PublishGroupSet { room, .. } => topo.room(*room).group_name.clone(),
            Effect::PublishDeviceSet { device, .. }
            | Effect::PublishDeviceGet { device }
            | Effect::PublishGetTrv { trv: device } => topo.device_name(*device).to_string(),
            Effect::PublishZwaveRefresh { plug } => topo.device_name(plug.device()).to_string(),
            // HA / raw → fall back to the full MQTT topic.
            other => other.topic(topo),
        }
    }

    fn payload_json(&self, _ep: &EventProcessor) -> String {
        self.payload_string()
    }
}

fn full_day(temp: f64) -> Vec<DayTimeRange> {
    vec![DayTimeRange {
        start_hour: 0,
        start_minute: 0,
        end_hour: 24,
        end_minute: 0,
        temperature: temp,
    }]
}

fn full_week(temp: f64) -> BTreeMap<Weekday, Vec<DayTimeRange>> {
    Weekday::ALL.iter().map(|&d| (d, full_day(temp))).collect()
}

fn two_period_day(day_temp: f64, night_temp: f64) -> Vec<DayTimeRange> {
    vec![
        DayTimeRange {
            start_hour: 0, start_minute: 0,
            end_hour: 8, end_minute: 0,
            temperature: night_temp,
        },
        DayTimeRange {
            start_hour: 8, start_minute: 0,
            end_hour: 22, end_minute: 0,
            temperature: day_temp,
        },
        DayTimeRange {
            start_hour: 22, start_minute: 0,
            end_hour: 24, end_minute: 0,
            temperature: night_temp,
        },
    ]
}

fn trv_dev(ieee: &str) -> DeviceCatalogEntry {
    DeviceCatalogEntry::Trv(CommonFields {
        ieee_address: ieee.into(),
        description: None,
        options: BTreeMap::from([
            ("operating_mode".into(), serde_json::json!("manual")),
        ]),
    })
}

fn wt_dev(ieee: &str) -> DeviceCatalogEntry {
    DeviceCatalogEntry::WallThermostat(CommonFields {
        ieee_address: ieee.into(),
        description: None,
        options: BTreeMap::from([
            ("heater_type".into(), serde_json::json!("manual_control")),
            ("operating_mode".into(), serde_json::json!("manual")),
        ]),
    })
}

fn make_config(
    zones: Vec<HeatingZone>,
    schedules: BTreeMap<String, TemperatureSchedule>,
    pressure_groups: Vec<PressureGroup>,
) -> Config {
    let mut devices: BTreeMap<String, DeviceCatalogEntry> = BTreeMap::new();
    for zone in &zones {
        devices.insert(zone.relay.clone(), wt_dev(&format!("0x{}", zone.relay)));
        for zt in &zone.trvs {
            devices.insert(zt.device.clone(), trv_dev(&format!("0x{}", zt.device)));
        }
    }
    Config {
        name_by_address: BTreeMap::new(),
        devices,
        rooms: vec![],
        switch_models: BTreeMap::new(),
        bindings: vec![],
        defaults: Defaults::default(),
        heating: Some(HeatingConfig {
            zones,
            schedules,
            pressure_groups,
            heat_pump: HeatPumpProtection {
                min_cycle_seconds: 120,
                min_pause_seconds: 60,
                min_demand_percent: 5,
                min_demand_percent_fallback: 80,
            },
            open_window: OpenWindowProtection {
                detection_minutes: 20,
                inhibit_minutes: 80,
            },
        }),
        location: None,
    }
}

fn simple_config() -> Config {
    make_config(
        vec![HeatingZone {
            name: "bath".into(),
            relay: "wt-bath".into(),
            trvs: vec![ZoneTrv {
                device: "trv-bath-1".into(),
                schedule: "bath-sched".into(),
            }],
        }],
        BTreeMap::from([(
            "bath-sched".into(),
            TemperatureSchedule { days: full_week(20.0) },
        )]),
        vec![],
    )
}

fn setup(cfg: &Config) -> (EventProcessor, Arc<FakeClock>) {
    let clk = Arc::new(FakeClock::new(12));
    let topo = Arc::new(Topology::build(cfg).unwrap());
    let defaults = cfg.defaults.clone();
    let mut ep = EventProcessor::new(topo, clk.clone(), defaults, None);
    // Simulate startup: mark all zones as relay-state-known (OFF),
    // seed pump_off_since, mark startup complete and WT refreshed.
    let heating_config = cfg.heating.as_ref().unwrap();
    for zone in &heating_config.zones {
        let hz = ep.world.heating_zone(&zone.name);
        hz.relay_state_known = true;
        hz.actual.update(HeatingZoneActual { relay_on: false, temperature: None }, clk.now());
    }
    ep.pump_off_since = Some(clk.now());
    ep.startup_complete = true;
    clk.advance(Duration::from_secs(120));
    ep.last_wt_refresh = Some(clk.now());
    (ep, clk)
}

fn echo_relay(ep: &mut EventProcessor, relay: &str, on: bool, clk: &FakeClock) {
    ep.handle_event(Event::WallThermostatState {
        device: relay.into(),
        relay_on: Some(on),
        local_temperature: None,
        operating_mode: None,
        ts: clk.now(),
    });
}

fn echo_setpoint(ep: &mut EventProcessor, trv: &str, temp: f64, clk: &FakeClock) {
    ep.handle_event(Event::TrvState {
        device: trv.into(),
        local_temperature: None,
        pi_heating_demand: None,
        running_state: None,
        occupied_heating_setpoint: Some(temp),
        operating_mode: None,
        battery: None,
        ts: clk.now(),
    });
}

fn send_trv_demand(ep: &mut EventProcessor, trv: &str, temp: f64, demand: u8, state: &str, setpoint: f64, clk: &FakeClock) {
    ep.handle_event(Event::TrvState {
        device: trv.into(),
        local_temperature: Some(temp),
        pi_heating_demand: Some(demand),
        running_state: Some(state.into()),
        occupied_heating_setpoint: Some(setpoint),
        operating_mode: None,
        battery: None,
        ts: clk.now(),
    });
}

fn tick(ep: &mut EventProcessor) -> Vec<Effect> {
    let ts = ep.clock.now();
    ep.handle_event(Event::Tick { ts })
}

// -- Schedule tests --

#[test]
fn schedule_sets_initial_setpoint() {
    let cfg = simple_config();
    let (mut ep, _clk) = setup(&cfg);
    let actions = tick(&mut ep);
    let sp: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "trv-bath-1")
        .collect();
    assert!(!sp.is_empty());
    let json = sp[0].payload_json(&ep);
    assert!(json.contains("20"));
}

#[test]
fn schedule_dedup_skips_redundant_setpoint() {
    let cfg = simple_config();
    let (mut ep, clk) = setup(&cfg);
    tick(&mut ep);
    echo_setpoint(&mut ep, "trv-bath-1", 20.0, &clk);
    let actions = tick(&mut ep);
    let sp: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "trv-bath-1")
        .collect();
    assert!(sp.is_empty(), "should not re-send confirmed setpoint");
}

#[test]
fn schedule_retries_unconfirmed_setpoint() {
    let cfg = simple_config();
    let (mut ep, _clk) = setup(&cfg);
    tick(&mut ep);
    let actions = tick(&mut ep);
    let sp: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "trv-bath-1")
        .collect();
    assert!(!sp.is_empty(), "should retry unconfirmed setpoint");
}

#[test]
fn schedule_updates_on_time_change() {
    let mut days = BTreeMap::new();
    for &d in &Weekday::ALL {
        days.insert(d, two_period_day(22.0, 18.0));
    }
    let cfg = make_config(
        vec![HeatingZone {
            name: "bath".into(),
            relay: "wt-bath".into(),
            trvs: vec![ZoneTrv { device: "trv-bath-1".into(), schedule: "sched".into() }],
        }],
        BTreeMap::from([("sched".into(), TemperatureSchedule { days })]),
        vec![],
    );
    let (mut ep, clk) = setup(&cfg);
    let actions = tick(&mut ep);
    assert!(!actions.is_empty());
    let json = actions[0].payload_json(&ep);
    assert!(json.contains("22"));
    echo_setpoint(&mut ep, "trv-bath-1", 22.0, &clk);
    clk.set_hour(23);
    let actions = tick(&mut ep);
    let sp: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "trv-bath-1"
            && a.payload_json(&ep).contains("18"))
        .collect();
    assert!(!sp.is_empty(), "should set new target on time change");
}

// -- Demand and relay tests --

#[test]
fn relay_turns_on_when_trv_demands_heat() {
    let cfg = simple_config();
    let (mut ep, clk) = setup(&cfg);
    tick(&mut ep);
    send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
    let actions = tick(&mut ep);
    let relay_on: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "wt-bath"
            && a.payload_json(&ep).contains("ON"))
        .collect();
    assert!(!relay_on.is_empty(), "should request relay ON");
}

#[test]
fn relay_turns_off_when_demand_stops() {
    let cfg = simple_config();
    let (mut ep, clk) = setup(&cfg);
    tick(&mut ep);
    send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
    tick(&mut ep);
    echo_relay(&mut ep, "wt-bath", true, &clk);
    clk.advance(Duration::from_secs(200));
    send_trv_demand(&mut ep, "trv-bath-1", 20.5, 0, "idle", 20.0, &clk);
    let actions = tick(&mut ep);
    let relay_off: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "wt-bath"
            && a.payload_json(&ep).contains("OFF"))
        .collect();
    assert!(!relay_off.is_empty(), "should request relay OFF");
}

// -- Short cycling tests --

#[test]
fn min_pause_blocks_relay_on() {
    let cfg = simple_config();
    let (mut ep, clk) = setup(&cfg);
    tick(&mut ep);
    ep.pump_off_since = Some(clk.now());
    clk.advance(Duration::from_secs(30));
    send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
    let actions = tick(&mut ep);
    let relay_on: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "wt-bath"
            && a.payload_json(&ep).contains("ON"))
        .collect();
    assert!(relay_on.is_empty(), "should block relay ON during min_pause");
    clk.advance(Duration::from_secs(40));
    let actions = tick(&mut ep);
    let relay_on: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "wt-bath"
            && a.payload_json(&ep).contains("ON"))
        .collect();
    assert!(!relay_on.is_empty(), "should allow relay ON after min_pause");
}

#[test]
fn min_cycle_blocks_relay_off() {
    let cfg = simple_config();
    let (mut ep, clk) = setup(&cfg);
    tick(&mut ep);
    send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
    tick(&mut ep);
    echo_relay(&mut ep, "wt-bath", true, &clk);
    send_trv_demand(&mut ep, "trv-bath-1", 20.5, 0, "idle", 20.0, &clk);
    clk.advance(Duration::from_secs(60));
    let actions = tick(&mut ep);
    let relay_off: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "wt-bath"
            && a.payload_json(&ep).contains("OFF"))
        .collect();
    assert!(relay_off.is_empty(), "should block relay OFF during min_cycle");
    clk.advance(Duration::from_secs(120));
    let actions = tick(&mut ep);
    let relay_off: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "wt-bath"
            && a.payload_json(&ep).contains("OFF"))
        .collect();
    assert!(!relay_off.is_empty(), "should allow relay OFF after min_cycle");
}

// -- Pressure group tests --

#[test]
fn pressure_group_forces_open_other_trvs() {
    let cfg = make_config(
        vec![HeatingZone {
            name: "bath".into(),
            relay: "wt-bath".into(),
            trvs: vec![
                ZoneTrv { device: "trv-1".into(), schedule: "s".into() },
                ZoneTrv { device: "trv-2".into(), schedule: "s".into() },
            ],
        }],
        BTreeMap::from([("s".into(), TemperatureSchedule { days: full_week(20.0) })]),
        vec![PressureGroup {
            name: "bath-group".into(),
            trvs: vec!["trv-1".into(), "trv-2".into()],
        }],
    );
    let (mut ep, clk) = setup(&cfg);
    tick(&mut ep);
    send_trv_demand(&mut ep, "trv-1", 18.0, 50, "heat", 20.0, &clk);
    tick(&mut ep);
    echo_relay(&mut ep, "wt-bath", true, &clk);
    let actions = tick(&mut ep);
    let forced: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "trv-2"
            && a.payload_json(&ep).contains("30"))
        .collect();
    assert_eq!(forced.len(), 1, "trv-2 should be forced to 30C");
}

// -- Open window tests --

#[test]
fn open_window_inhibits_trv() {
    let mut cfg = simple_config();
    cfg.heating.as_mut().unwrap().open_window = OpenWindowProtection {
        detection_minutes: 1,
        inhibit_minutes: 2,
    };
    let (mut ep, clk) = setup(&cfg);
    tick(&mut ep);
    send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
    tick(&mut ep);
    echo_relay(&mut ep, "wt-bath", true, &clk);
    clk.advance(Duration::from_secs(5));
    send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
    clk.advance(Duration::from_secs(65));
    send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
    let actions = tick(&mut ep);
    let inhibit: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "trv-bath-1"
            && a.payload_json(&ep).contains("\"occupied_heating_setpoint\":5"))
        .collect();
    assert!(!inhibit.is_empty(), "TRV should be inhibited via setpoint 5C");
    let trv = ep.world.trvs.get("trv-bath-1").unwrap();
    assert!(trv.is_inhibited(clk.now()));
}

// -- Mode enforcement --

#[test]
fn trv_mode_drift_triggers_reassertion() {
    let cfg = simple_config();
    let (mut ep, clk) = setup(&cfg);
    tick(&mut ep);
    let actions = ep.handle_event(Event::TrvState {
        device: "trv-bath-1".into(),
        local_temperature: Some(20.0),
        pi_heating_demand: None,
        running_state: None,
        occupied_heating_setpoint: None,
        operating_mode: Some("schedule".into()),
        battery: None,
        ts: clk.now(),
    });
    let mode: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "trv-bath-1"
            && a.payload_json(&ep).contains("manual"))
        .collect();
    assert!(!mode.is_empty(), "TRV mode drift must trigger reassertion");
}

#[test]
fn wall_thermostat_mode_drift_triggers_reassertion() {
    let cfg = simple_config();
    let (mut ep, clk) = setup(&cfg);
    tick(&mut ep);
    let actions = ep.handle_event(Event::WallThermostatState {
        device: "wt-bath".into(),
        relay_on: Some(false),
        local_temperature: Some(22.0),
        operating_mode: Some("schedule".into()),
        ts: clk.now(),
    });
    let mode: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "wt-bath"
            && a.payload_json(&ep).contains("manual"))
        .collect();
    assert!(!mode.is_empty(), "wall thermostat mode drift must trigger reassertion");
}

// -- Reconciliation tests --

#[test]
fn relay_reconciliation_retries_unconfirmed() {
    let cfg = simple_config();
    let (mut ep, clk) = setup(&cfg);
    tick(&mut ep);
    send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
    tick(&mut ep); // emits relay ON
    // No echo.
    let actions = tick(&mut ep);
    let relay_on: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "wt-bath"
            && a.payload_json(&ep).contains("ON"))
        .collect();
    assert!(!relay_on.is_empty(), "should retry unconfirmed relay ON");
}

#[test]
fn setpoint_reconciliation_retries_on_divergence() {
    let cfg = simple_config();
    let (mut ep, clk) = setup(&cfg);
    tick(&mut ep); // sets setpoint to 20.0
    ep.handle_event(Event::TrvState {
        device: "trv-bath-1".into(),
        local_temperature: Some(18.0),
        pi_heating_demand: None,
        running_state: None,
        occupied_heating_setpoint: Some(15.0), // wrong
        operating_mode: None,
        battery: None,
        ts: clk.now(),
    });
    let actions = tick(&mut ep);
    let retries: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "trv-bath-1"
            && a.payload_json(&ep).contains("20"))
        .collect();
    assert!(!retries.is_empty(), "should retry diverged setpoint");
}

#[test]
fn no_duplicate_commands_on_same_tick() {
    let cfg = simple_config();
    let (mut ep, _clk) = setup(&cfg);
    let actions = tick(&mut ep);
    let sp: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "trv-bath-1")
        .collect();
    assert_eq!(sp.len(), 1, "should emit exactly one setpoint command per tick");
}

// -- Min cycle forcing --

#[test]
fn min_cycle_forces_trvs_open_when_blocking_relay_off() {
    let cfg = simple_config();
    let (mut ep, clk) = setup(&cfg);
    tick(&mut ep);
    send_trv_demand(&mut ep, "trv-bath-1", 18.0, 50, "heat", 20.0, &clk);
    tick(&mut ep);
    echo_relay(&mut ep, "wt-bath", true, &clk);
    send_trv_demand(&mut ep, "trv-bath-1", 20.5, 0, "idle", 20.0, &clk);
    clk.advance(Duration::from_secs(60));
    let actions = tick(&mut ep);
    let relay_off: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "wt-bath"
            && a.payload_json(&ep).contains("OFF"))
        .collect();
    assert!(relay_off.is_empty(), "relay OFF should be blocked by min_cycle");
    let trv_forced: Vec<_> = actions.iter()
        .filter(|a| a.target_name(&ep) == "trv-bath-1"
            && a.payload_json(&ep).contains("30"))
        .collect();
    assert!(!trv_forced.is_empty(), "TRV should be forced to 30C during min_cycle hold");
    let trv = ep.world.trvs.get("trv-bath-1").unwrap();
    assert!(trv.is_forced_open());
}
