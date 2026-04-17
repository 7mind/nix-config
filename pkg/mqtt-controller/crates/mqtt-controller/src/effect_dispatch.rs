//! Translate the typed [`Effect`] vocabulary into MQTT publishes via the
//! [`MqttBridge`]. The dispatcher is the single boundary where indexes
//! are converted back into wire-level topic strings.
//!
//! Dispatch records a [`TouchedEntities`] set so the daemon can drive
//! incremental WebSocket broadcasts from the actual side-effects
//! produced by an event, rather than re-broadcasting every room/plug/
//! heating zone after every event.

use std::collections::BTreeSet;

use crate::domain::Effect;
use crate::domain::event::Event;
use crate::domain::ha_discovery;
use crate::mqtt::{MqttBridge, MqttError};
use crate::topology::{DeviceIdx, PlugIdx, RoomIdx, Topology, ZoneIdx};

/// Set of entities touched by a batch of dispatched effects. Used by the
/// daemon's event loop to issue incremental broadcasts instead of a
/// full sweep.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TouchedEntities {
    pub rooms: BTreeSet<RoomIdx>,
    pub plugs: BTreeSet<PlugIdx>,
    pub heating_zones: BTreeSet<ZoneIdx>,
    /// Individual lights whose actual state changed.
    pub lights: BTreeSet<DeviceIdx>,
}

impl TouchedEntities {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn touch_room(&mut self, room: RoomIdx) {
        self.rooms.insert(room);
    }

    pub fn touch_plug(&mut self, plug: PlugIdx) {
        self.plugs.insert(plug);
    }

    pub fn touch_zone(&mut self, zone: ZoneIdx) {
        self.heating_zones.insert(zone);
    }

    pub fn touch_light(&mut self, light: DeviceIdx) {
        self.lights.insert(light);
    }

    /// Touch the device if it's a plug; otherwise no-op. Used by
    /// effects that target arbitrary devices (e.g. wall thermostat
    /// relays).
    pub fn touch_device_as_plug(&mut self, topology: &Topology, device: DeviceIdx) {
        if let Some(plug) = topology.plug_idx(device) {
            self.touch_plug(plug);
        }
    }

    /// If the device is a TRV that belongs to a heating zone, touch
    /// that zone too.
    pub fn touch_zone_for_trv(&mut self, topology: &Topology, trv: DeviceIdx) {
        let trv_name = topology.device_name(trv);
        if let Some(cfg) = topology.heating_config() {
            for (i, zone) in cfg.zones.iter().enumerate() {
                if zone.trvs.iter().any(|zt| zt.device == trv_name) {
                    self.touch_zone(ZoneIdx::new(i as u32));
                }
            }
        }
    }

    /// If the device is a wall thermostat that owns a heating zone,
    /// touch that zone.
    pub fn touch_zone_for_relay(&mut self, topology: &Topology, relay: DeviceIdx) {
        let relay_name = topology.device_name(relay);
        if let Some(cfg) = topology.heating_config() {
            for (i, zone) in cfg.zones.iter().enumerate() {
                if zone.relay == relay_name {
                    self.touch_zone(ZoneIdx::new(i as u32));
                }
            }
        }
    }

    /// Merge another touched-set into this one.
    pub fn extend(&mut self, other: TouchedEntities) {
        self.rooms.extend(other.rooms);
        self.plugs.extend(other.plugs);
        self.heating_zones.extend(other.heating_zones);
        self.lights.extend(other.lights);
    }
}

/// Compute the touched-entities set implied by an inbound [`Event`]
/// before [`crate::logic::EventProcessor::handle_event`] runs. Inbound
/// state events (`GroupState`, `PlugState`, telemetry) mutate
/// `WorldState` without emitting effects, so the daemon needs this
/// signal in addition to [`dispatch`]'s effect-derived set to keep
/// dashboard broadcasts honest.
pub fn touched_from_event(event: &Event, topology: &Topology) -> TouchedEntities {
    let mut touched = TouchedEntities::new();
    match event {
        Event::Occupancy { sensor, .. } => {
            for &room in topology.rooms_for_motion(sensor) {
                touched.touch_room(room);
            }
        }
        Event::GroupState { group, .. } => {
            if let Some(room) = topology.room_idx_by_group(group) {
                touched.touch_room(room);
                // Group state changes propagate to rule-bearing
                // descendant rooms (`handle_group_state` calls
                // `propagate_to_descendants`); reflect that in the
                // touched set so the dashboard updates the whole
                // affected subtree, not just the parent.
                for &desc in topology.descendants_of(room) {
                    touched.touch_room(desc);
                }
            }
        }
        Event::PlugState { device, .. } | Event::PlugPowerUpdate { device, .. } => {
            if let Some(plug_idx) = topology.plug_idx_by_name(device) {
                touched.touch_plug(plug_idx);
            }
        }
        Event::LightState { device, .. } => {
            if let Some(dev) = topology.device_idx(device) {
                touched.touch_light(dev);
            }
        }
        Event::TrvState { device, .. } => {
            if let Some(dev) = topology.device_idx(device) {
                touched.touch_zone_for_trv(topology, dev);
            }
        }
        Event::WallThermostatState { device, .. } => {
            if let Some(dev) = topology.device_idx(device) {
                touched.touch_zone_for_relay(topology, dev);
            }
        }
        Event::ButtonPress { .. } | Event::Tick { .. } => {}
    }
    touched
}

/// Translate a batch of [`Effect`]s into MQTT publishes via `bridge`,
/// returning the set of touched entities for downstream broadcast.
///
/// Errors from individual publishes are logged but do not abort the
/// batch — the rest of the side-effects still need to fire. This
/// matches the previous `for action in actions { ... }` semantics.
pub async fn dispatch(
    bridge: &MqttBridge,
    topology: &Topology,
    effects: &[Effect],
) -> TouchedEntities {
    let mut touched = TouchedEntities::new();
    for effect in effects {
        match dispatch_one(bridge, topology, effect, &mut touched).await {
            Ok(()) => {}
            Err(e) => {
                tracing::error!(error = ?e, ?effect, "failed to dispatch effect");
            }
        }
    }
    touched
}

async fn dispatch_one(
    bridge: &MqttBridge,
    topology: &Topology,
    effect: &Effect,
    touched: &mut TouchedEntities,
) -> Result<(), MqttError> {
    match effect {
        Effect::PublishGroupSet { room, payload } => {
            touched.touch_room(*room);
            // Logic propagates state to rule-bearing descendant rooms
            // (`propagate_to_descendants` / `publish_off`) when a room
            // turns on or off, so the dashboard needs updates for those
            // too.
            for &desc in topology.descendants_of(*room) {
                touched.touch_room(desc);
            }
            let group_name = topology.room(*room).group_name.clone();
            bridge.publish_group_set(&group_name, payload).await
        }
        Effect::PublishDeviceSet { device, payload } => {
            // Touch device's plug (if it's a plug) or its zone (if it's
            // a TRV or relay) so downstream broadcast covers the right
            // entity.
            touched.touch_device_as_plug(topology, *device);
            touched.touch_zone_for_trv(topology, *device);
            touched.touch_zone_for_relay(topology, *device);
            let device_name = topology.device_name(*device).to_string();
            let is_zwave = topology.is_zwave_plug_idx(*device);
            bridge.publish_device_set(&device_name, payload, is_zwave).await
        }
        Effect::PublishDeviceGet { device } => {
            let device_name = topology.device_name(*device);
            bridge.publish_get(device_name).await
        }
        Effect::PublishGetTrv { trv } => {
            let device_name = topology.device_name(*trv);
            bridge.publish_get_trv(device_name).await
        }
        Effect::PublishZwaveRefresh { plug } => {
            // Need the node_id; look it up in the zwave_node_id map
            // (which stores the inverse of what we want).
            let dev_idx = plug.device();
            // Find the node_id for this plug device.
            let device_name = topology.device_name(dev_idx);
            let node_id = topology
                .zwave_node_id_to_name()
                .into_iter()
                .find(|(_, name)| *name == device_name)
                .map(|(id, _)| id);
            if let Some(node_id) = node_id {
                bridge.publish_zwave_refresh(node_id).await
            } else {
                Ok(())
            }
        }
        Effect::PublishHaDiscoveryZone { zone } => {
            let cfg = topology
                .heating_config()
                .expect("zone effect requires heating config");
            let zone_cfg = &cfg.zones[zone.as_usize()];
            let publish = ha_discovery::zone_discovery_publish(&zone_cfg.name);
            bridge.publish_raw(&publish.topic, publish.payload.as_bytes(), true).await
        }
        Effect::PublishHaDiscoveryTrv { trv } => {
            let trv_name = topology.device_name(*trv);
            let publish = ha_discovery::trv_discovery_publish(trv_name);
            bridge.publish_raw(&publish.topic, publish.payload.as_bytes(), true).await
        }
        Effect::PublishHaStateZone { zone, state } => {
            touched.touch_zone(*zone);
            let cfg = topology
                .heating_config()
                .expect("zone effect requires heating config");
            let zone_cfg = &cfg.zones[zone.as_usize()];
            let topic = ha_discovery::state_topic("zone", &zone_cfg.name);
            bridge.publish_raw(&topic, state.as_bytes(), true).await
        }
        Effect::PublishHaStateTrv { trv, state } => {
            touched.touch_zone_for_trv(topology, *trv);
            let trv_name = topology.device_name(*trv);
            let topic = ha_discovery::state_topic("trv", trv_name);
            bridge.publish_raw(&topic, state.as_bytes(), true).await
        }
        Effect::PublishRaw { topic, payload, retain } => {
            bridge.publish_raw(topic, payload.as_bytes(), *retain).await
        }
    }
}

#[cfg(test)]
mod tests {
    //! Regression tests for the websocket-broadcast pipeline. The
    //! daemon's incremental `broadcast_touched` only fires for
    //! entities in the touched set; missing entries here would mean
    //! a silently stale dashboard after group/plug/TRV echoes or
    //! after parent-room state changes that propagate to children.
    //!
    //! Relevant Codex review finding (2026-04): inbound state events
    //! mutate `WorldState` without emitting effects, and
    //! `propagate_to_descendants` mutates child rooms that aren't the
    //! direct effect target. Both code paths must show up in
    //! `TouchedEntities`.
    use std::collections::BTreeMap;
    use std::sync::Arc;
    use std::time::Instant;

    use super::*;
    use crate::config::scenes::{Scene, SceneSchedule, Slot};
    use crate::config::switch_model::SwitchModel;
    use crate::config::{
        Binding, CommonFields, Config, Defaults, DeviceCatalogEntry, Effect as CfgEffect,
        Room, TimeExpr, Trigger as CfgTrigger,
    };
    use crate::config::heating::{
        DayTimeRange, HeatPumpProtection, HeatingConfig, HeatingZone, OpenWindowProtection,
        TemperatureSchedule, Weekday, ZoneTrv,
    };

    fn day_scenes() -> SceneSchedule {
        SceneSchedule {
            scenes: vec![Scene {
                id: 1,
                name: "x".into(),
                state: "ON".into(),
                brightness: None,
                color_temp: None,
                transition: 0.0,
            }],
            slots: BTreeMap::from([(
                "day".into(),
                Slot {
                    from: TimeExpr::Fixed { minute_of_day: 0 },
                    to: TimeExpr::Fixed { minute_of_day: 1440 },
                    scene_ids: vec![1],
                },
            )]),
        }
    }

    fn light(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Light(CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::new(),
        })
    }

    fn motion_sensor(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::MotionSensor {
            common: CommonFields {
                ieee_address: ieee.into(),
                description: None,
                options: BTreeMap::new(),
            },
            occupancy_timeout_seconds: 60,
            max_illuminance: None,
        }
    }

    fn plug(ieee: &str) -> DeviceCatalogEntry {
        use crate::config::catalog::PlugProtocol;
        DeviceCatalogEntry::Plug {
            common: CommonFields {
                ieee_address: ieee.into(),
                description: None,
                options: BTreeMap::new(),
            },
            variant: "test-plug".into(),
            capabilities: vec!["on-off".into(), "power".into()],
            protocol: PlugProtocol::Zigbee,
            node_id: None,
        }
    }

    fn trv(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::Trv(CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::from([(
                "operating_mode".into(),
                serde_json::json!("manual"),
            )]),
        })
    }

    fn wt(ieee: &str) -> DeviceCatalogEntry {
        DeviceCatalogEntry::WallThermostat(CommonFields {
            ieee_address: ieee.into(),
            description: None,
            options: BTreeMap::from([
                ("operating_mode".into(), serde_json::json!("manual")),
                ("heater_type".into(), serde_json::json!("manual_control")),
            ]),
        })
    }

    fn always_on_schedule() -> TemperatureSchedule {
        let day = vec![DayTimeRange {
            start_hour: 0,
            start_minute: 0,
            end_hour: 24,
            end_minute: 0,
            temperature: 21.0,
        }];
        TemperatureSchedule {
            days: Weekday::ALL.iter().map(|&d| (d, day.clone())).collect(),
        }
    }

    /// Fixture used by every test in this module. Two rooms
    /// (parent + child), one plug, one motion sensor, one heating zone
    /// with a TRV and wall thermostat.
    fn make_topology_simple() -> Arc<Topology> {
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([
                ("hue-l-parent".into(), light("0xa")),
                ("hue-l-child".into(), light("0xb")),
                ("hue-ms-parent".into(), motion_sensor("0xc")),
                ("z2m-p-test".into(), plug("0xd")),
                ("trv-bath".into(), trv("0xe")),
                ("wt-bath".into(), wt("0xf")),
                ("hue-s-test".into(), DeviceCatalogEntry::Switch {
                    common: CommonFields {
                        ieee_address: "0x10".into(),
                        description: None,
                        options: BTreeMap::new(),
                    },
                    model: "test-1btn".into(),
                }),
            ]),
            switch_models: BTreeMap::from([(
                "test-1btn".into(),
                SwitchModel {
                    buttons: vec!["on".into()],
                    z2m_action_map: BTreeMap::from([(
                        "on_press".into(),
                        crate::config::switch_model::ActionMapping {
                            button: "on".into(),
                            gesture: crate::config::switch_model::Gesture::Press,
                        },
                    )]),
                },
            )]),
            rooms: vec![
                Room {
                    name: "parent".into(),
                    group_name: "hue-lz-parent".into(),
                    id: 1,
                    members: vec!["hue-l-parent/11".into(), "hue-l-child/11".into()],
                    parent: None,
                    motion_sensors: vec!["hue-ms-parent".into()],
                    scenes: day_scenes(),
                    off_transition_seconds: 0.8,
                    motion_off_cooldown_seconds: 0,
                },
                Room {
                    name: "child".into(),
                    group_name: "hue-lz-child".into(),
                    id: 2,
                    members: vec!["hue-l-child/11".into()],
                    parent: Some("parent".into()),
                    motion_sensors: vec![],
                    scenes: day_scenes(),
                    off_transition_seconds: 0.8,
                    motion_off_cooldown_seconds: 0,
                },
            ],
            bindings: vec![
                // Bind a switch press to the child room so `child` qualifies
                // as a rule-bearing descendant of `parent`.
                Binding {
                    name: "child-cycle".into(),
                    trigger: CfgTrigger::Button {
                        device: "hue-s-test".into(),
                        button: "on".into(),
                        gesture: crate::config::switch_model::Gesture::Press,
                    },
                    effect: CfgEffect::SceneCycle { room: "child".into() },
                },
            ],
            defaults: Defaults::default(),
            heating: Some(HeatingConfig {
                zones: vec![HeatingZone {
                    name: "bath".into(),
                    relay: "wt-bath".into(),
                    trvs: vec![ZoneTrv {
                        device: "trv-bath".into(),
                        schedule: "always-on".into(),
                    }],
                }],
                schedules: BTreeMap::from([(
                    "always-on".into(),
                    always_on_schedule(),
                )]),
                pressure_groups: vec![],
                heat_pump: HeatPumpProtection {
                    min_cycle_seconds: 60,
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
        };
        Arc::new(Topology::build(&cfg).expect("build topology"))
    }

    fn now() -> Instant {
        Instant::now()
    }

    #[test]
    fn touched_from_group_state_includes_room_and_descendants() {
        // Codex regression: a `GroupState` echo for the parent room
        // also propagates to rule-bearing descendants in
        // `handle_group_state`. The dashboard must see updates for
        // both, not just the parent.
        let topo = make_topology_simple();
        let event = Event::GroupState {
            group: "hue-lz-parent".into(),
            on: true,
            ts: now(),
        };
        let touched = touched_from_event(&event, &topo);

        let parent = topo.room_idx("parent").unwrap();
        let child = topo.room_idx("child").unwrap();
        assert!(touched.rooms.contains(&parent), "parent missing from touched set");
        assert!(touched.rooms.contains(&child), "child descendant missing from touched set");
    }

    #[test]
    fn touched_from_plug_state_includes_plug() {
        let topo = make_topology_simple();
        let event = Event::PlugState {
            device: "z2m-p-test".into(),
            on: true,
            power: Some(42.0),
            ts: now(),
        };
        let touched = touched_from_event(&event, &topo);

        let plug = topo.plug_idx_by_name("z2m-p-test").unwrap();
        assert!(touched.plugs.contains(&plug), "plug missing from touched set");
    }

    #[test]
    fn touched_from_plug_power_update_includes_plug() {
        let topo = make_topology_simple();
        let event = Event::PlugPowerUpdate {
            device: "z2m-p-test".into(),
            watts: 1.2,
            ts: now(),
        };
        let touched = touched_from_event(&event, &topo);
        let plug = topo.plug_idx_by_name("z2m-p-test").unwrap();
        assert!(touched.plugs.contains(&plug), "plug missing from touched set");
    }

    #[test]
    fn touched_from_trv_state_includes_zone() {
        let topo = make_topology_simple();
        let event = Event::TrvState {
            device: "trv-bath".into(),
            local_temperature: Some(20.0),
            pi_heating_demand: Some(10),
            running_state: Some("heat".into()),
            occupied_heating_setpoint: Some(21.0),
            operating_mode: Some("manual".into()),
            battery: Some(80),
            ts: now(),
        };
        let touched = touched_from_event(&event, &topo);
        let zone = ZoneIdx::new(0);
        assert!(
            touched.heating_zones.contains(&zone),
            "heating zone missing from touched set after TRV telemetry"
        );
    }

    #[test]
    fn touched_from_wall_thermostat_state_includes_zone() {
        let topo = make_topology_simple();
        let event = Event::WallThermostatState {
            device: "wt-bath".into(),
            relay_on: Some(true),
            local_temperature: Some(20.0),
            operating_mode: Some("manual".into()),
            ts: now(),
        };
        let touched = touched_from_event(&event, &topo);
        let zone = ZoneIdx::new(0);
        assert!(
            touched.heating_zones.contains(&zone),
            "heating zone missing from touched set after WT telemetry"
        );
    }

    #[test]
    fn touched_from_occupancy_includes_motion_room() {
        let topo = make_topology_simple();
        let event = Event::Occupancy {
            sensor: "hue-ms-parent".into(),
            occupied: true,
            illuminance: Some(50),
            ts: now(),
        };
        let touched = touched_from_event(&event, &topo);
        let parent = topo.room_idx("parent").unwrap();
        assert!(touched.rooms.contains(&parent), "motion-driven room missing from touched set");
    }

    #[test]
    fn touched_from_button_press_is_empty() {
        // Effects emitted by `handle_event` will populate the touched
        // set; the event itself contributes nothing structural.
        let topo = make_topology_simple();
        let event = Event::ButtonPress {
            device: "hue-s-test".into(),
            button: "on".into(),
            gesture: crate::config::switch_model::Gesture::Press,
            ts: now(),
        };
        let touched = touched_from_event(&event, &topo);
        assert!(touched.rooms.is_empty());
        assert!(touched.plugs.is_empty());
        assert!(touched.heating_zones.is_empty());
    }
}
