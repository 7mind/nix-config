//! MQTT bridge: parses incoming z2m messages into [`crate::domain::Event`],
//! serializes [`crate::domain::Action`] back to z2m's wire format, drives
//! the rumqttc event loop.
//!
//! Architecture:
//!
//!   * [`MqttBridge`] is the public handle. Construct via
//!     [`MqttBridge::start`], which connects to the broker, subscribes to
//!     all the topics the topology cares about, spawns a tokio task to
//!     drive the rumqttc event loop, and hands back:
//!       - the bridge handle (for publishing actions and `/get` queries)
//!       - an `mpsc::Receiver<Event>` the daemon's main loop polls
//!
//!   * The event loop runs in its own tokio task. It owns the rumqttc
//!     `EventLoop` and forwards every parseable Publish into the channel
//!     as an [`Event`]. Unrelated MQTT control packets (PingResp, etc)
//!     are silently ignored.
//!
//!   * Outbound publishes go through the `AsyncClient` clone the bridge
//!     holds. They're awaitable and bubble up [`MqttError`] on failure.
//!
//! ## Topic conventions
//!
//! z2m publishes to:
//!   - `zigbee2mqtt/<friendly_name>/action` for switch and tap action
//!     codes (plain text payload like `"on_press_release"` / `"press_1"`)
//!   - `zigbee2mqtt/<friendly_name>` for device state (motion sensors)
//!     and group state (z2m aggregates member states into per-group state)
//!
//! We dispatch by suffix:
//!   - `/action` → look up the friendly name in switch / tap indexes
//!   - bare → look up in motion sensor / group indexes
//!
//! Each name is unique across all four kinds (the topology validator
//! enforces this implicitly: the same friendly name can't be both a
//! switch and a tap).

pub mod codec;
pub mod topics;

use std::sync::Arc;
use std::time::{Duration, Instant};

use rumqttc::{AsyncClient, EventLoop, MqttOptions, Publish, QoS};
use thiserror::Error;
use tokio::sync::mpsc;

use crate::domain::action::Action;
use crate::domain::event::{Event, SwitchAction, parse_tap_action};
use crate::time::Clock;
use crate::topology::Topology;

/// MQTT connection parameters.
#[derive(Debug, Clone)]
pub struct MqttConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub client_id: String,
    pub keep_alive: Duration,
}

impl MqttConfig {
    pub fn new(
        host: impl Into<String>,
        port: u16,
        user: impl Into<String>,
        password: impl Into<String>,
        client_id: impl Into<String>,
    ) -> Self {
        Self {
            host: host.into(),
            port,
            user: user.into(),
            password: password.into(),
            client_id: client_id.into(),
            keep_alive: Duration::from_secs(30),
        }
    }
}

#[derive(Debug, Error)]
pub enum MqttError {
    #[error("rumqttc client error: {0}")]
    Client(#[from] rumqttc::ClientError),

    #[error("payload serialize failed: {0}")]
    Serialize(#[from] serde_json::Error),
}

/// Public handle. Holds the MQTT client and the topology used for parsing.
#[derive(Clone)]
pub struct MqttBridge {
    client: AsyncClient,
    topology: Arc<Topology>,
    clock: Arc<dyn Clock>,
}

impl MqttBridge {
    /// Connect, subscribe, and spawn the event-loop task.
    ///
    /// On success returns the bridge handle plus a `Receiver<Event>` the
    /// daemon's main loop polls. The event-loop task runs until the
    /// channel is dropped (i.e. when the daemon shuts down).
    pub async fn start(
        config: MqttConfig,
        topology: Arc<Topology>,
        clock: Arc<dyn Clock>,
    ) -> Result<(Self, mpsc::Receiver<Event>), MqttError> {
        let mut opts = MqttOptions::new(&config.client_id, &config.host, config.port);
        opts.set_credentials(&config.user, &config.password);
        opts.set_keep_alive(config.keep_alive);
        // Bigger inflight window — we'll briefly burst a lot of /get
        // publishes during startup state refresh.
        opts.set_inflight(50);
        // rumqttc defaults to a 10 KB max incoming packet, which is too
        // small for z2m bridge inventory payloads (~200 KB) and could
        // also bite on large group state messages. Bump to 2 MB so the
        // eventloop never trips on a legitimate z2m publish. See the
        // matching note in `provision::client`.
        opts.set_max_packet_size(2 * 1024 * 1024, 2 * 1024 * 1024);

        let (client, eventloop) = AsyncClient::new(opts, 256);

        // Subscribe to every topic we care about. Doing this BEFORE
        // spawning the event loop ensures the SUBACKs come in once
        // polling starts; rumqttc queues the subscribe commands.
        Self::subscribe_all(&client, &topology).await?;

        let (tx, rx) = mpsc::channel(512);
        let topology_for_loop = topology.clone();
        let clock_for_loop = clock.clone();
        tokio::spawn(run_eventloop(eventloop, tx, topology_for_loop, clock_for_loop));

        Ok((
            Self {
                client,
                topology,
                clock,
            },
            rx,
        ))
    }

    async fn subscribe_all(
        client: &AsyncClient,
        topology: &Topology,
    ) -> Result<(), MqttError> {
        // Switches: action topics
        for sw in topology.all_switch_names() {
            client
                .subscribe(topics::device_action_topic(sw), QoS::AtLeastOnce)
                .await?;
        }
        // Taps: action topics
        for tap in topology.all_tap_names() {
            client
                .subscribe(topics::device_action_topic(tap), QoS::AtLeastOnce)
                .await?;
        }
        // Motion sensors: state topic
        for sensor in topology.all_motion_sensor_names() {
            client
                .subscribe(topics::state_topic(sensor), QoS::AtLeastOnce)
                .await?;
        }
        // Groups: state topic (for physical_on tracking, including
        // retained messages on initial subscribe)
        for group in topology.all_group_names() {
            client
                .subscribe(topics::state_topic(group), QoS::AtLeastOnce)
                .await?;
        }
        // Zigbee plugs: state topic (for on/off + power monitoring)
        for plug in topology.all_plug_names() {
            if !topology.is_zwave_plug(plug) {
                client
                    .subscribe(topics::state_topic(plug), QoS::AtLeastOnce)
                    .await?;
            }
        }
        // TRVs: state topic (for temperature, demand, setpoint)
        for trv in topology.all_trv_names() {
            client
                .subscribe(topics::state_topic(trv), QoS::AtLeastOnce)
                .await?;
        }
        // Wall thermostats: state topic (for relay state, temperature)
        for wt in topology.all_wall_thermostat_names() {
            client
                .subscribe(topics::state_topic(wt), QoS::AtLeastOnce)
                .await?;
        }
        // Z-Wave plugs: separate topics for switch state and power meter
        for plug in topology.zwave_plug_names() {
            client
                .subscribe(topics::zwave_switch_state_topic(plug), QoS::AtLeastOnce)
                .await?;
            client
                .subscribe(topics::zwave_meter_power_topic(plug), QoS::AtLeastOnce)
                .await?;
        }
        Ok(())
    }

    /// Publish an [`Action`] to the corresponding `/set` topic.
    /// For Z-Wave plugs, translates to the Z-Wave JS UI wire format.
    pub async fn publish_action(&self, action: &Action) -> Result<(), MqttError> {
        use crate::domain::action::ActionTarget;
        let name = action.target_name();
        match &action.target {
            ActionTarget::DeviceGet(_) => {
                // GET actions go to the /get topic, not /set.
                let topic = topics::get_topic(name);
                let payload = serde_json::to_vec(&action.payload)?;
                self.client
                    .publish(topic, QoS::AtLeastOnce, false, payload)
                    .await?;
            }
            _ if self.topology.is_zwave_plug(name) => {
                // Z-Wave plugs: publish true/false to switch_binary targetValue
                let on = match &action.payload {
                    crate::domain::action::Payload::DeviceStateSet { state } => *state == "ON",
                    other => {
                        tracing::warn!(
                            device = name,
                            payload = ?other,
                            "unexpected payload type for zwave plug; ignoring"
                        );
                        return Ok(());
                    }
                };
                let topic = topics::zwave_switch_set_topic(name);
                let payload = if on { b"true".as_slice() } else { b"false".as_slice() };
                self.client
                    .publish(topic, QoS::AtLeastOnce, false, payload)
                    .await?;
            }
            _ => {
                let topic = topics::set_topic(name);
                let payload = serde_json::to_vec(&action.payload)?;
                self.client
                    .publish(topic, QoS::AtLeastOnce, false, payload)
                    .await?;
            }
        }
        Ok(())
    }

    /// Publish a `{"state": ""}` to `<name>/get` to force z2m to query
    /// the current state and re-publish it on the matching state topic.
    /// Used by the startup state refresh for groups and Zigbee plugs
    /// whose retained messages didn't arrive.
    pub async fn publish_get(&self, name: &str) -> Result<(), MqttError> {
        let topic = topics::get_topic(name);
        self.client
            .publish(topic, QoS::AtLeastOnce, false, br#"{"state":""}"#.as_slice())
            .await?;
        Ok(())
    }

    /// Request a fresh value publish for a Z-Wave node's binary switch
    /// state. Publishes a `writeValue` API call that reads (not writes)
    /// the current value, causing Z-Wave JS UI to re-publish the
    /// `currentValue` topic.
    ///
    /// Z-Wave JS UI doesn't support the zigbee2mqtt-style `<topic>/get`
    /// pattern, so we use the MQTT API's `refreshValues` command instead.
    pub async fn publish_zwave_refresh(
        &self,
        node_id: u16,
    ) -> Result<(), MqttError> {
        let topic = format!(
            "{}refreshValues/set",
            crate::mqtt::codec::zwave_api::GATEWAY_PREFIX,
        );
        let payload = serde_json::json!({"args": [node_id]});
        self.client
            .publish(topic, QoS::AtLeastOnce, false, serde_json::to_vec(&payload)?)
            .await?;
        Ok(())
    }

    /// Publish a `/get` for TRV climate attributes that the heating
    /// controller needs: temperature, demand, running state, setpoint.
    /// Unlike `publish_get` which sends `{"state":""}`, this queries
    /// the specific climate attributes Bosch BTH-RA exposes.
    pub async fn publish_get_trv(&self, name: &str) -> Result<(), MqttError> {
        let topic = topics::get_topic(name);
        let payload = br#"{"local_temperature":"","pi_heating_demand":"","running_state":"","occupied_heating_setpoint":"","operating_mode":"","battery":""}"#;
        self.client
            .publish(topic, QoS::AtLeastOnce, false, payload.as_slice())
            .await?;
        Ok(())
    }

    /// Borrow the topology — useful when the caller already has the
    /// bridge but needs to enumerate groups for the state-refresh logic.
    pub fn topology(&self) -> &Arc<Topology> {
        &self.topology
    }
}

async fn run_eventloop(mut eventloop: EventLoop, tx: mpsc::Sender<Event>, topology: Arc<Topology>, clock: Arc<dyn Clock>) {
    loop {
        match eventloop.poll().await {
            Ok(rumqttc::Event::Incoming(rumqttc::Packet::Publish(p))) => {
                if let Some(event) = parse_event(&topology, &p, &*clock) {
                    if tx.send(event).await.is_err() {
                        // Receiver dropped → daemon shutting down.
                        break;
                    }
                }
            }
            Ok(_) => {}
            Err(e) => {
                tracing::warn!(error = ?e, "mqtt event loop error; retrying after 1s");
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }
}

/// Translate a raw MQTT publish into an [`Event`]. Returns `None` for
/// messages we don't care about (unknown topic, malformed payload,
/// unrecognized action). The whole controller/runtime tolerates `None`
/// — we never panic on bad input from the broker.
fn parse_event(topology: &Topology, p: &Publish, clock: &dyn Clock) -> Option<Event> {
    let now = clock.now();
    let topic = p.topic.as_str();

    // Z-Wave topics are under `zwave/` — try those first.
    if let Some(event) = parse_zwave_event(topology, topic, &p.payload, now) {
        return Some(event);
    }

    // Strip the `zigbee2mqtt/` prefix; everything we care about lives
    // under that namespace.
    let rest = topic.strip_prefix("zigbee2mqtt/")?;

    // Action topics → switch or tap. The friendly name is everything
    // between the prefix and `/action`.
    if let Some(name) = rest.strip_suffix("/action") {
        let payload_text = std::str::from_utf8(&p.payload).ok()?.trim_matches('"');
        // Switch dispatch first (action set is disjoint from tap's, so
        // even if the same name appeared as both — which is impossible —
        // we'd recognize the right one). A switch qualifies if it's bound
        // to a room OR if it has action rules (SwitchOn/SwitchOff).
        if !topology.rooms_for_switch(name).is_empty()
            || topology.has_switch_actions(name)
        {
            let action = SwitchAction::parse(payload_text)?;
            return Some(Event::SwitchAction {
                device: name.to_string(),
                action,
                ts: now,
            });
        }
        if topology.all_tap_names().contains(name) {
            let parsed = parse_tap_action(payload_text)?;
            return Some(Event::TapAction {
                device: name.to_string(),
                button: parsed.button,
                action: parsed.action,
                ts: now,
            });
        }
        return None;
    }

    // State topic → motion sensor or group. The friendly name is the
    // entire `rest`. We branch by topology lookup.
    let name = rest;

    if topology.room_by_group_name(name).is_some() {
        // Group state. z2m aggregates member states; we read the
        // top-level `state` field.
        let value: serde_json::Value = serde_json::from_slice(&p.payload).ok()?;
        let state_str = value.get("state")?.as_str()?;
        let on = state_str.eq_ignore_ascii_case("ON");
        return Some(Event::GroupState {
            group: name.to_string(),
            on,
            ts: now,
        });
    }

    if topology.is_plug(name) {
        // Plug state. z2m publishes state + optional power reading.
        let value: serde_json::Value = serde_json::from_slice(&p.payload).ok()?;
        let state_str = value.get("state")?.as_str()?;
        let on = state_str.eq_ignore_ascii_case("ON");
        let power = value
            .get("power")
            .and_then(|v| v.as_f64());
        return Some(Event::PlugState {
            device: name.to_string(),
            on,
            power,
            ts: now,
        });
    }

    if topology.is_trv(name) {
        let value: serde_json::Value = serde_json::from_slice(&p.payload).ok()?;
        let local_temperature = value.get("local_temperature").and_then(|v| v.as_f64());
        let pi_heating_demand = value
            .get("pi_heating_demand")
            .and_then(|v| v.as_u64())
            .map(|n| n.min(100) as u8);
        let running_state = value
            .get("running_state")
            .and_then(|v| v.as_str())
            .map(String::from);
        let occupied_heating_setpoint = value
            .get("occupied_heating_setpoint")
            .and_then(|v| v.as_f64());
        let operating_mode = value
            .get("operating_mode")
            .and_then(|v| v.as_str())
            .map(String::from);
        let battery = value
            .get("battery")
            .and_then(|v| v.as_u64())
            .map(|n| n.min(100) as u8);
        return Some(Event::TrvState {
            device: name.to_string(),
            local_temperature,
            pi_heating_demand,
            running_state,
            occupied_heating_setpoint,
            operating_mode,
            battery,
            ts: now,
        });
    }

    if topology.is_wall_thermostat(name) {
        let value: serde_json::Value = serde_json::from_slice(&p.payload).ok()?;
        let relay_on = value
            .get("state")
            .and_then(|v| v.as_str())
            .map(|s| s.eq_ignore_ascii_case("ON"));
        let local_temperature = value.get("local_temperature").and_then(|v| v.as_f64());
        let operating_mode = value
            .get("operating_mode")
            .and_then(|v| v.as_str())
            .map(String::from);
        return Some(Event::WallThermostatState {
            device: name.to_string(),
            relay_on,
            local_temperature,
            operating_mode,
            ts: now,
        });
    }

    if !topology.rooms_for_motion(name).is_empty() {
        let value: serde_json::Value = serde_json::from_slice(&p.payload).ok()?;
        let occupied = value.get("occupancy")?.as_bool()?;
        let illuminance = value
            .get("illuminance")
            .and_then(|v| v.as_u64())
            .map(|n| n as u32);
        return Some(Event::Occupancy {
            sensor: name.to_string(),
            occupied,
            illuminance,
            ts: now,
        });
    }

    None
}

/// Parse a Z-Wave JS UI MQTT message into an [`Event`]. Z-Wave JS UI
/// publishes each value on its own topic with a wrapper payload:
/// `{"time":…,"value":<actual>,"nodeName":"…","nodeLocation":"…"}`.
///
/// We care about two topic shapes per Z-Wave plug:
///   - `zwave/<name>/switch_binary/endpoint_0/currentValue` → on/off
///   - `zwave/<name>/meter/endpoint_0/value/66049` → power (watts)
fn parse_zwave_event(
    topology: &Topology,
    topic: &str,
    payload: &[u8],
    now: Instant,
) -> Option<Event> {
    let rest = topic.strip_prefix("zwave/")?;

    // Binary switch state: zwave/<name>/switch_binary/endpoint_0/currentValue
    if let Some(name) = rest.strip_suffix("/switch_binary/endpoint_0/currentValue") {
        if !topology.is_zwave_plug(name) {
            return None;
        }
        let value: serde_json::Value = serde_json::from_slice(payload).ok()?;
        let on = value.get("value")?.as_bool()?;
        return Some(Event::PlugState {
            device: name.to_string(),
            on,
            power: None,
            ts: now,
        });
    }

    // Meter power reading: zwave/<name>/meter/endpoint_0/value/66049
    let meter_suffix = format!("/meter/endpoint_0/value/{}", codec::zwave_meter::POWER_W);
    if let Some(name) = rest.strip_suffix(&meter_suffix) {
        if !topology.is_zwave_plug(name) {
            return None;
        }
        let value: serde_json::Value = serde_json::from_slice(payload).ok()?;
        let watts = value.get("value")?.as_f64()?;
        // NAS-WR01ZE is known to send bogus large negative meter
        // reports; clamp to zero at parse time as first line of defense.
        // The controller also clamps uniformly in handle_plug_state.
        let watts = watts.max(0.0);
        return Some(Event::PlugPowerUpdate {
            device: name.to_string(),
            watts,
            ts: now,
        });
    }

    None
}

#[cfg(test)]
mod tests {
    //! Parser tests. The MQTT client itself is exercised by the
    //! integration tests against rumqttd.

    use super::*;
    use crate::config::catalog::PlugProtocol;
    use crate::config::scenes::{Scene, SceneSchedule, Slot};
    use crate::config::{
        ActionRule, CommonFields, Config, DeviceBinding, DeviceCatalogEntry, Defaults,
        Effect, Room, Trigger,
    };
    use crate::time::FakeClock;
    use std::collections::BTreeMap;

    fn clock() -> FakeClock {
        FakeClock::new(12)
    }

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
                    from: crate::config::TimeExpr::Fixed { minute_of_day: 0 },
                    to: crate::config::TimeExpr::Fixed { minute_of_day: 1440 },
                    scene_ids: vec![1],
                },
            )]),
        }
    }

    fn small_topology() -> Arc<Topology> {
        let cfg = Config {
            name_by_address: BTreeMap::new(),
            devices: BTreeMap::from([
                (
                    "hue-l-a".into(),
                    DeviceCatalogEntry::Light(CommonFields {
                        ieee_address: "0xa".into(),
                        description: None,
                        options: BTreeMap::new(),
                    }),
                ),
                (
                    "hue-s-study".into(),
                    DeviceCatalogEntry::Switch(CommonFields {
                        ieee_address: "0x1".into(),
                        description: None,
                        options: BTreeMap::new(),
                    }),
                ),
                (
                    "hue-ts-foo".into(),
                    DeviceCatalogEntry::Tap(CommonFields {
                        ieee_address: "0x2".into(),
                        description: None,
                        options: BTreeMap::new(),
                    }),
                ),
                (
                    "hue-ms-study".into(),
                    DeviceCatalogEntry::MotionSensor {
                        common: CommonFields {
                            ieee_address: "0x3".into(),
                            description: None,
                            options: BTreeMap::new(),
                        },
                        occupancy_timeout_seconds: 60,
                        max_illuminance: None,
                    },
                ),
                (
                    "z2m-p-printer".into(),
                    DeviceCatalogEntry::Plug {
                        common: CommonFields {
                            ieee_address: "0xf".into(),
                            description: None,
                            options: BTreeMap::new(),
                        },
                        variant: "sonoff-power".into(),
                        capabilities: vec!["on-off".into(), "power".into()],
                        protocol: PlugProtocol::Zigbee,
                        node_id: None,
                    },
                ),
                (
                    "zneo-p-attic-desk".into(),
                    DeviceCatalogEntry::Plug {
                        common: CommonFields {
                            ieee_address: "zwave:6".into(),
                            description: None,
                            options: BTreeMap::new(),
                        },
                        variant: "neo-nas-wr01ze".into(),
                        capabilities: vec!["on-off".into(), "power".into()],
                        protocol: PlugProtocol::Zwave,
                        node_id: Some(6),
                    },
                ),
            ]),
            rooms: vec![Room {
                name: "study".into(),
                group_name: "hue-lz-study".into(),
                id: 1,
                members: vec!["hue-l-a/11".into()],
                parent: None,
                devices: vec![
                    DeviceBinding {
                        device: "hue-s-study".into(),
                        button: None,
                        cycle_on_double_tap: false,
                    },
                    DeviceBinding {
                        device: "hue-ts-foo".into(),
                        button: Some(1),
                        cycle_on_double_tap: false,
                    },
                    DeviceBinding {
                        device: "hue-ms-study".into(),
                        button: None,
                        cycle_on_double_tap: false,
                    },
                ],
                scenes: day_scenes(),
                off_transition_seconds: 0.8,
                motion_off_cooldown_seconds: 0,
            }],
            actions: vec![ActionRule {
                name: "printer-kill".into(),
                trigger: Trigger::PowerBelow {
                    device: "z2m-p-printer".into(),
                    watts: 5.0,
                    for_seconds: 300,
                },
                effect: Effect::TurnOff {
                    target: "z2m-p-printer".into(),
                },
            }],
            defaults: Defaults::default(),
            heating: None,
            location: None,
        };
        Arc::new(Topology::build(&cfg).unwrap())
    }

    fn publish(topic: &str, payload: &str) -> Publish {
        Publish::new(topic, QoS::AtLeastOnce, payload.as_bytes().to_vec())
    }

    #[test]
    fn parse_switch_action() {
        let topo = small_topology();
        let p = publish("zigbee2mqtt/hue-s-study/action", "on_press_release");
        let event = parse_event(&topo, &p, &clock()).unwrap();
        match event {
            Event::SwitchAction {
                device,
                action: SwitchAction::OnPressRelease,
                ..
            } => assert_eq!(device, "hue-s-study"),
            other => panic!("expected SwitchAction OnPressRelease, got {other:?}"),
        }
    }

    #[test]
    fn parse_tap_action() {
        let topo = small_topology();
        let p = publish("zigbee2mqtt/hue-ts-foo/action", "press_1");
        let event = parse_event(&topo, &p, &clock()).unwrap();
        match event {
            Event::TapAction { device, button, .. } => {
                assert_eq!(device, "hue-ts-foo");
                assert_eq!(button, 1);
            }
            other => panic!("expected TapAction, got {other:?}"),
        }
    }

    #[test]
    fn parse_group_state_on() {
        let topo = small_topology();
        let p = publish(
            "zigbee2mqtt/hue-lz-study",
            r#"{"state":"ON","brightness":254}"#,
        );
        let event = parse_event(&topo, &p, &clock()).unwrap();
        match event {
            Event::GroupState { group, on, .. } => {
                assert_eq!(group, "hue-lz-study");
                assert!(on);
            }
            other => panic!("expected GroupState, got {other:?}"),
        }
    }

    #[test]
    fn parse_group_state_off() {
        let topo = small_topology();
        let p = publish("zigbee2mqtt/hue-lz-study", r#"{"state":"OFF"}"#);
        let event = parse_event(&topo, &p, &clock()).unwrap();
        match event {
            Event::GroupState { on: false, .. } => {}
            other => panic!("expected GroupState off, got {other:?}"),
        }
    }

    #[test]
    fn parse_motion_with_illuminance() {
        let topo = small_topology();
        let p = publish(
            "zigbee2mqtt/hue-ms-study",
            r#"{"occupancy":true,"illuminance":42,"battery":97}"#,
        );
        let event = parse_event(&topo, &p, &clock()).unwrap();
        match event {
            Event::Occupancy {
                sensor,
                occupied,
                illuminance,
                ..
            } => {
                assert_eq!(sensor, "hue-ms-study");
                assert!(occupied);
                assert_eq!(illuminance, Some(42));
            }
            other => panic!("expected Occupancy, got {other:?}"),
        }
    }

    #[test]
    fn parse_motion_without_illuminance() {
        let topo = small_topology();
        let p = publish("zigbee2mqtt/hue-ms-study", r#"{"occupancy":false}"#);
        let event = parse_event(&topo, &p, &clock()).unwrap();
        match event {
            Event::Occupancy {
                occupied: false,
                illuminance: None,
                ..
            } => {}
            other => panic!("expected Occupancy off, got {other:?}"),
        }
    }

    #[test]
    fn unknown_topic_returns_none() {
        let topo = small_topology();
        let p = publish("zigbee2mqtt/hue-l-other/action", "on_press_release");
        assert!(parse_event(&topo, &p, &clock()).is_none());
    }

    #[test]
    fn malformed_payload_returns_none() {
        let topo = small_topology();
        let p = publish("zigbee2mqtt/hue-lz-study", "not json");
        assert!(parse_event(&topo, &p, &clock()).is_none());
    }

    #[test]
    fn unknown_switch_action_returns_none() {
        let topo = small_topology();
        let p = publish("zigbee2mqtt/hue-s-study/action", "long_press");
        assert!(parse_event(&topo, &p, &clock()).is_none());
    }

    #[test]
    fn parse_plug_state_on_with_power() {
        let topo = small_topology();
        let p = publish(
            "zigbee2mqtt/z2m-p-printer",
            r#"{"state":"ON","power":120.5,"energy":42.1}"#,
        );
        let event = parse_event(&topo, &p, &clock()).unwrap();
        match event {
            Event::PlugState {
                device,
                on,
                power,
                ..
            } => {
                assert_eq!(device, "z2m-p-printer");
                assert!(on);
                assert!((power.unwrap() - 120.5).abs() < f64::EPSILON);
            }
            other => panic!("expected PlugState, got {other:?}"),
        }
    }

    #[test]
    fn parse_plug_state_off_no_power() {
        let topo = small_topology();
        let p = publish(
            "zigbee2mqtt/z2m-p-printer",
            r#"{"state":"OFF"}"#,
        );
        let event = parse_event(&topo, &p, &clock()).unwrap();
        match event {
            Event::PlugState {
                on,
                power,
                ..
            } => {
                assert!(!on);
                assert!(power.is_none());
            }
            other => panic!("expected PlugState off, got {other:?}"),
        }
    }

    #[test]
    fn plug_state_takes_priority_over_unknown() {
        let topo = small_topology();
        // Even though z2m-p-printer is not a group or sensor, it should
        // parse as PlugState, not return None.
        let p = publish(
            "zigbee2mqtt/z2m-p-printer",
            r#"{"state":"ON","power":0.5}"#,
        );
        assert!(matches!(
            parse_event(&topo, &p, &clock()),
            Some(Event::PlugState { .. })
        ));
    }

    // ---- Z-Wave plug tests ------------------------------------------------

    #[test]
    fn parse_zwave_switch_on() {
        let topo = small_topology();
        let p = publish(
            "zwave/zneo-p-attic-desk/switch_binary/endpoint_0/currentValue",
            r#"{"time":1775507352385,"value":true,"nodeName":"zneo-p-attic-desk","nodeLocation":""}"#,
        );
        let event = parse_event(&topo, &p, &clock()).unwrap();
        match event {
            Event::PlugState { device, on, power, .. } => {
                assert_eq!(device, "zneo-p-attic-desk");
                assert!(on);
                assert!(power.is_none());
            }
            other => panic!("expected PlugState, got {other:?}"),
        }
    }

    #[test]
    fn parse_zwave_switch_off() {
        let topo = small_topology();
        let p = publish(
            "zwave/zneo-p-attic-desk/switch_binary/endpoint_0/currentValue",
            r#"{"time":1775507352385,"value":false,"nodeName":"zneo-p-attic-desk","nodeLocation":""}"#,
        );
        let event = parse_event(&topo, &p, &clock()).unwrap();
        match event {
            Event::PlugState { on, .. } => assert!(!on),
            other => panic!("expected PlugState off, got {other:?}"),
        }
    }

    #[test]
    fn parse_zwave_meter_power() {
        let topo = small_topology();
        let p = publish(
            "zwave/zneo-p-attic-desk/meter/endpoint_0/value/66049",
            r#"{"time":1775507242082,"value":42.5,"nodeName":"zneo-p-attic-desk","nodeLocation":""}"#,
        );
        let event = parse_event(&topo, &p, &clock()).unwrap();
        match event {
            Event::PlugPowerUpdate { device, watts, .. } => {
                assert_eq!(device, "zneo-p-attic-desk");
                assert!((watts - 42.5).abs() < f64::EPSILON);
            }
            other => panic!("expected PlugPowerUpdate, got {other:?}"),
        }
    }

    #[test]
    fn parse_zwave_meter_negative_clamped_to_zero() {
        let topo = small_topology();
        // NAS-WR01ZE sends bogus negative values occasionally.
        let p = publish(
            "zwave/zneo-p-attic-desk/meter/endpoint_0/value/66049",
            r#"{"time":1775507242082,"value":-12345.6,"nodeName":"zneo-p-attic-desk","nodeLocation":""}"#,
        );
        let event = parse_event(&topo, &p, &clock()).unwrap();
        match event {
            Event::PlugPowerUpdate { watts, .. } => {
                assert_eq!(watts, 0.0);
            }
            other => panic!("expected PlugPowerUpdate, got {other:?}"),
        }
    }

    #[test]
    fn zwave_unknown_device_returns_none() {
        let topo = small_topology();
        let p = publish(
            "zwave/unknown-device/switch_binary/endpoint_0/currentValue",
            r#"{"time":0,"value":true,"nodeName":"","nodeLocation":""}"#,
        );
        assert!(parse_event(&topo, &p, &clock()).is_none());
    }

    #[test]
    fn zwave_unrelated_topic_returns_none() {
        let topo = small_topology();
        let p = publish(
            "zwave/zneo-p-attic-desk/configuration/endpoint_0/LED_Indicator",
            r#"{"time":0,"value":1,"nodeName":"","nodeLocation":""}"#,
        );
        assert!(parse_event(&topo, &p, &clock()).is_none());
    }
}
