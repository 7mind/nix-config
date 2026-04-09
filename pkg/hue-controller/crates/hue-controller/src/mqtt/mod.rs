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
        tokio::spawn(run_eventloop(eventloop, tx, topology_for_loop));

        Ok((
            Self {
                client,
                topology,
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
        // Plugs: state topic (for on/off + power monitoring)
        for plug in topology.all_plug_names() {
            client
                .subscribe(topics::state_topic(plug), QoS::AtLeastOnce)
                .await?;
        }
        Ok(())
    }

    /// Publish an [`Action`] to the corresponding `/set` topic.
    pub async fn publish_action(&self, action: &Action) -> Result<(), MqttError> {
        let topic = topics::set_topic(action.target_name());
        let payload = serde_json::to_vec(&action.payload)?;
        self.client
            .publish(topic, QoS::AtLeastOnce, false, payload)
            .await?;
        Ok(())
    }

    /// Publish a `{"state": ""}` to `<group>/get` to force z2m to query
    /// the current state and re-publish it on the matching state topic.
    /// Used by the startup state refresh for groups whose retained
    /// messages didn't arrive.
    pub async fn publish_get(&self, group_name: &str) -> Result<(), MqttError> {
        let topic = topics::get_topic(group_name);
        self.client
            .publish(topic, QoS::AtLeastOnce, false, br#"{"state":""}"#.as_slice())
            .await?;
        Ok(())
    }

    /// Borrow the topology — useful when the caller already has the
    /// bridge but needs to enumerate groups for the state-refresh logic.
    pub fn topology(&self) -> &Arc<Topology> {
        &self.topology
    }
}

async fn run_eventloop(mut eventloop: EventLoop, tx: mpsc::Sender<Event>, topology: Arc<Topology>) {
    loop {
        match eventloop.poll().await {
            Ok(rumqttc::Event::Incoming(rumqttc::Packet::Publish(p))) => {
                if let Some(event) = parse_event(&topology, &p) {
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
fn parse_event(topology: &Topology, p: &Publish) -> Option<Event> {
    let now = Instant::now();
    let topic = p.topic.as_str();

    // Strip the `zigbee2mqtt/` prefix; everything we care about lives
    // under that namespace.
    let rest = topic.strip_prefix("zigbee2mqtt/")?;

    // Action topics → switch or tap. The friendly name is everything
    // between the prefix and `/action`.
    if let Some(name) = rest.strip_suffix("/action") {
        let payload_text = std::str::from_utf8(&p.payload).ok()?.trim_matches('"');
        // Switch dispatch first (action set is disjoint from tap's, so
        // even if the same name appeared as both — which is impossible —
        // we'd recognize the right one).
        if !topology.rooms_for_switch(name).is_empty() {
            let action = SwitchAction::parse(payload_text)?;
            return Some(Event::SwitchAction {
                device: name.to_string(),
                action,
                ts: now,
            });
        }
        if topology.all_tap_names().contains(name) {
            let button = parse_tap_action(payload_text)?;
            return Some(Event::TapAction {
                device: name.to_string(),
                button,
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

#[cfg(test)]
mod tests {
    //! Parser tests. The MQTT client itself is exercised by the
    //! integration tests against rumqttd.

    use super::*;
    use crate::config::scenes::{Scene, SceneSchedule, Slot};
    use crate::config::{
        ActionRule, CommonFields, Config, DeviceBinding, DeviceCatalogEntry, Defaults,
        Effect, Room, Trigger,
    };
    use std::collections::BTreeMap;

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
                    start_hour: 0,
                    end_hour_exclusive: 24,
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
                    },
                    DeviceBinding {
                        device: "hue-ts-foo".into(),
                        button: Some(1),
                    },
                    DeviceBinding {
                        device: "hue-ms-study".into(),
                        button: None,
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
        let event = parse_event(&topo, &p).unwrap();
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
        let event = parse_event(&topo, &p).unwrap();
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
        let event = parse_event(&topo, &p).unwrap();
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
        let event = parse_event(&topo, &p).unwrap();
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
        let event = parse_event(&topo, &p).unwrap();
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
        let event = parse_event(&topo, &p).unwrap();
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
        assert!(parse_event(&topo, &p).is_none());
    }

    #[test]
    fn malformed_payload_returns_none() {
        let topo = small_topology();
        let p = publish("zigbee2mqtt/hue-lz-study", "not json");
        assert!(parse_event(&topo, &p).is_none());
    }

    #[test]
    fn unknown_switch_action_returns_none() {
        let topo = small_topology();
        let p = publish("zigbee2mqtt/hue-s-study/action", "long_press");
        assert!(parse_event(&topo, &p).is_none());
    }

    #[test]
    fn parse_plug_state_on_with_power() {
        let topo = small_topology();
        let p = publish(
            "zigbee2mqtt/z2m-p-printer",
            r#"{"state":"ON","power":120.5,"energy":42.1}"#,
        );
        let event = parse_event(&topo, &p).unwrap();
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
        let event = parse_event(&topo, &p).unwrap();
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
            parse_event(&topo, &p),
            Some(Event::PlugState { .. })
        ));
    }
}
