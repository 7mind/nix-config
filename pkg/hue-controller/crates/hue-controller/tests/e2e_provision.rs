//! End-to-end tests for the Z2mClient provisioning helpers — fetches,
//! requests, retained-message handling. Spawns an embedded `rumqttd`
//! and feeds it carefully-staged retained messages to mirror what the
//! real z2m bridge publishes.
//!
//! We don't actually run the full reconcile() against this broker; that
//! would require a fake "z2m bridge responder" simulating the
//! request/response protocol z2m exposes on `bridge/request/...` and
//! `bridge/response/...`. The bits worth covering here are the parts
//! that broke in production: retained-message fetches.

mod common;

use std::time::Duration;

use common::{TestBroker, TestClient};
use hue_controller::mqtt::MqttConfig;
use hue_controller::provision::Z2mClient;

#[tokio::test]
async fn fetch_devices_returns_retained_payload() {
    let broker = TestBroker::start().await;

    // Stage the retained payload BEFORE starting the Z2mClient, so a
    // fresh client subscribing to bridge/devices gets it on first
    // SUBACK. Mirrors the production case where z2m has been running
    // and has long since published its inventory.
    let publisher = TestClient::connect(&broker, "test-publisher").await;
    publisher
        .publish_retained(
            "zigbee2mqtt/bridge/devices",
            r#"[{"ieee_address":"0xaa","friendly_name":"hue-l-foo"}]"#,
        )
        .await;
    // Brief pause so the broker definitely persists the retain before
    // the Z2mClient connects.
    tokio::time::sleep(Duration::from_millis(100)).await;

    let mqtt = MqttConfig::new(
        "127.0.0.1",
        broker.port,
        "test",
        "",
        "z2m-client-test",
    );
    let client = Z2mClient::connect(mqtt, Duration::from_secs(3))
        .await
        .expect("connect");

    let devices = client
        .fetch_devices()
        .await
        .expect("fetch_devices should return the retained payload");

    assert_eq!(devices.len(), 1);
    assert_eq!(devices[0].ieee_address, "0xaa");
    assert_eq!(devices[0].friendly_name, "hue-l-foo");

    client.shutdown().await;
}

#[tokio::test]
async fn fetch_devices_handles_large_retained_payload() {
    // Regression test for the production failure where bridge/devices
    // for a 50-device mesh weighs ~200 KB and rumqttc's default
    // 10 KB max-packet-size errors out the eventloop, dropping the
    // publish before our cache sees it. The fix bumps the limit to
    // 2 MB; this test pushes a 250 KB payload through the path to
    // make sure that's enough.
    let broker = TestBroker::start().await;

    let publisher = TestClient::connect(&broker, "test-publisher-large").await;
    // Build a large but well-formed JSON device array — 1000 entries
    // each with a 250-byte padded friendly_name puts us well over the
    // 200 KB threshold that bit production.
    let mut entries = Vec::with_capacity(1000);
    for i in 0..1000 {
        let padding = "x".repeat(250);
        entries.push(format!(
            r#"{{"ieee_address":"0x{:016x}","friendly_name":"hue-l-{}-{}"}}"#,
            i, i, padding
        ));
    }
    let payload = format!("[{}]", entries.join(","));
    assert!(
        payload.len() > 200_000,
        "test payload should be > 200 KB to exercise the size limit; got {} bytes",
        payload.len()
    );
    publisher
        .publish_retained("zigbee2mqtt/bridge/devices", &payload)
        .await;
    tokio::time::sleep(Duration::from_millis(150)).await;

    let mqtt = MqttConfig::new(
        "127.0.0.1",
        broker.port,
        "test",
        "",
        "z2m-client-test-large",
    );
    let client = Z2mClient::connect(mqtt, Duration::from_secs(5))
        .await
        .expect("connect");

    let devices = client
        .fetch_devices()
        .await
        .expect("fetch_devices should handle a >200 KB retained payload");

    assert_eq!(devices.len(), 1000);
    assert_eq!(devices[0].ieee_address, "0x0000000000000000");

    client.shutdown().await;
}

#[tokio::test]
async fn fetch_devices_times_out_when_no_retained_message() {
    let broker = TestBroker::start().await;

    // No retained message published. fetch_devices should time out
    // (cleanly, without panicking).
    let mqtt = MqttConfig::new(
        "127.0.0.1",
        broker.port,
        "test",
        "",
        "z2m-client-test-timeout",
    );
    let client = Z2mClient::connect(mqtt, Duration::from_secs(2))
        .await
        .expect("connect");

    let result = client.fetch_devices().await;
    assert!(
        matches!(
            result,
            Err(hue_controller::provision::client::Z2mClientError::FetchTimeout { .. })
        ),
        "expected FetchTimeout, got {result:?}"
    );

    client.shutdown().await;
}
