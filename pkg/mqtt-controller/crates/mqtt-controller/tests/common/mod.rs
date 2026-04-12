//! Shared fixtures for end-to-end tests. Spawns an embedded `rumqttd`
//! broker on a random localhost port and exposes a tiny `TestClient`
//! wrapper around `rumqttc::AsyncClient` for publishing test messages
//! and waiting on responses.
//!
//! Each test gets its own broker instance so they can run in parallel
//! without sharing state.

#![allow(dead_code)] // shared across tests; not every test uses every helper

pub mod fixtures;

use std::collections::HashMap;
use std::net::{SocketAddr, TcpListener};
use std::sync::Arc;
use std::time::Duration;

use rumqttc::{AsyncClient, EventLoop, MqttOptions, QoS};
use rumqttd::{
    Broker, Config, ConnectionSettings, RouterConfig, ServerSettings,
};
use tokio::sync::{Mutex, mpsc};

/// Find an unused TCP port by binding to port 0 and reading the
/// assigned one back. There's a tiny race window between drop and the
/// broker rebinding, but it's fine for tests.
fn pick_free_port() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    listener
        .local_addr()
        .expect("local_addr")
        .port()
}

fn broker_config(port: u16) -> Config {
    let connection = ConnectionSettings {
        connection_timeout_ms: 60_000,
        // Bumped from rumqttd's example default of 20 KB so the
        // large-payload regression test (~250 KB bridge/devices) can
        // actually pass through the broker. Mosquitto's default is
        // 256 MB, so 4 MB is comfortably below any realistic limit
        // and well above any plausible z2m payload.
        max_payload_size: 4 * 1024 * 1024,
        max_inflight_count: 100,
        auth: None,
        external_auth: None,
        dynamic_filters: false,
    };
    let server = ServerSettings {
        name: format!("test-v4-{port}"),
        listen: format!("127.0.0.1:{port}").parse::<SocketAddr>().unwrap(),
        tls: None,
        next_connection_delay_ms: 1,
        connections: connection,
    };
    let mut v4 = HashMap::new();
    v4.insert("test-v4".to_string(), server);

    Config {
        id: 0,
        router: RouterConfig {
            max_connections: 1024,
            max_outgoing_packet_count: 200,
            max_segment_size: 104_857_600,
            max_segment_count: 10,
            ..Default::default()
        },
        v4: Some(v4),
        v5: None,
        ws: None,
        cluster: None,
        console: None,
        bridge: None,
        prometheus: None,
        metrics: None,
    }
}

/// An embedded broker handle. The broker runs on a background OS
/// thread (rumqttd is sync internally) and dies with the process — no
/// explicit shutdown is required, which keeps tests simple at the cost
/// of leaving threads alive between tests in the same process. Test
/// processes are short-lived so this is fine.
pub struct TestBroker {
    pub port: u16,
}

impl TestBroker {
    /// Spin up a broker on a random port and wait until it's accepting
    /// connections.
    pub async fn start() -> Self {
        let port = pick_free_port();
        let config = broker_config(port);
        std::thread::spawn(move || {
            let mut broker = Broker::new(config);
            // start() blocks; we never return from here. The thread
            // dies when the process exits.
            let _ = broker.start();
        });

        // Poll until we can establish a TCP connection. The MQTT layer
        // will SUBACK shortly after, but a successful TCP connect is a
        // good enough readiness signal for tests.
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        loop {
            if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
                // Give the broker one more brief beat to fully come up.
                tokio::time::sleep(Duration::from_millis(50)).await;
                break;
            }
            if std::time::Instant::now() >= deadline {
                panic!("test broker on port {port} did not become ready in 3s");
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        TestBroker { port }
    }
}

/// Inbox of messages received on subscribed topics, keyed by topic.
#[derive(Default)]
pub struct Inbox {
    msgs: Mutex<HashMap<String, Vec<Vec<u8>>>>,
}

impl Inbox {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    async fn record(&self, topic: String, payload: Vec<u8>) {
        let mut guard = self.msgs.lock().await;
        guard.entry(topic).or_default().push(payload);
    }

    /// Wait until at least `count` messages have arrived on `topic`.
    /// Returns those messages (and any extras that came along) in
    /// arrival order. Panics on timeout.
    pub async fn wait_for(&self, topic: &str, count: usize, timeout: Duration) -> Vec<Vec<u8>> {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            {
                let guard = self.msgs.lock().await;
                if let Some(msgs) = guard.get(topic)
                    && msgs.len() >= count
                {
                    return msgs.clone();
                }
            }
            if std::time::Instant::now() >= deadline {
                let guard = self.msgs.lock().await;
                let observed = guard
                    .get(topic)
                    .map(|m| m.len())
                    .unwrap_or(0);
                panic!(
                    "timeout waiting for {count} messages on {topic:?} \
                     (observed {observed} after {timeout:?})"
                );
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    /// Number of messages received on `topic` so far.
    pub async fn count(&self, topic: &str) -> usize {
        let guard = self.msgs.lock().await;
        guard.get(topic).map(|m| m.len()).unwrap_or(0)
    }
}

/// A small async MQTT client tied to one inbox. Used by tests to
/// publish raw zigbee2mqtt messages and observe what the daemon
/// publishes back to a `<group>/set` topic.
pub struct TestClient {
    client: AsyncClient,
    pub inbox: Arc<Inbox>,
}

impl TestClient {
    pub async fn connect(broker: &TestBroker, client_id: &str) -> Self {
        let mut opts = MqttOptions::new(client_id, "127.0.0.1", broker.port);
        opts.set_keep_alive(Duration::from_secs(30));
        // Match the production client's max packet size so tests can
        // exercise the same large-payload paths the daemon supports.
        opts.set_max_packet_size(2 * 1024 * 1024, 2 * 1024 * 1024);
        let (client, eventloop) = AsyncClient::new(opts, 200);
        let inbox = Inbox::new();
        let inbox_for_loop = inbox.clone();
        tokio::spawn(run_client_loop(eventloop, inbox_for_loop));
        Self { client, inbox }
    }

    pub async fn subscribe(&self, topic: &str) {
        self.client
            .subscribe(topic, QoS::AtLeastOnce)
            .await
            .expect("subscribe");
    }

    /// Publish a NON-retained message. Use this for action / state
    /// events from "z2m".
    pub async fn publish(&self, topic: &str, payload: &str) {
        self.client
            .publish(topic, QoS::AtLeastOnce, false, payload.as_bytes().to_vec())
            .await
            .expect("publish");
    }

    /// Publish a RETAINED message. Use this to seed the broker with
    /// "current group state" before the daemon connects, so the
    /// daemon's startup state-refresh phase 1 picks it up.
    pub async fn publish_retained(&self, topic: &str, payload: &str) {
        self.client
            .publish(topic, QoS::AtLeastOnce, true, payload.as_bytes().to_vec())
            .await
            .expect("publish retained");
    }

    /// Drop the inflight publish queue and disconnect cleanly.
    pub async fn disconnect(&self) {
        let _ = self.client.disconnect().await;
    }
}

async fn run_client_loop(mut eventloop: EventLoop, inbox: Arc<Inbox>) {
    loop {
        match eventloop.poll().await {
            Ok(rumqttc::Event::Incoming(rumqttc::Packet::Publish(p))) => {
                inbox
                    .record(p.topic.clone(), p.payload.to_vec())
                    .await;
            }
            Ok(_) => {}
            Err(_) => {
                // Test client errors are usually "broker shut down".
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    }
}

/// Spawn a daemon against the test broker. Returns a JoinHandle the
/// caller can `abort()` at the end of the test. The daemon shares the
/// same in-process broker as the TestClient, so messages flow normally.
pub fn spawn_daemon(
    config: mqtt_controller::config::Config,
    broker: &TestBroker,
    clock: Arc<dyn mqtt_controller::time::Clock>,
) -> mpsc::Sender<()> {
    use mqtt_controller::mqtt::MqttConfig;

    let (shutdown_tx, mut shutdown_rx) = mpsc::channel::<()>(1);
    let mqtt = MqttConfig::new(
        "127.0.0.1",
        broker.port,
        "test",
        "",
        format!("mqtt-controller-test-{}", uuid::Uuid::new_v4()),
    );
    tokio::spawn(async move {
        let daemon_fut = mqtt_controller::daemon::run(config, mqtt, clock, None);
        tokio::select! {
            res = daemon_fut => {
                if let Err(e) = res {
                    eprintln!("test daemon exited with error: {e:?}");
                }
            }
            _ = shutdown_rx.recv() => {}
        }
    });
    shutdown_tx
}
