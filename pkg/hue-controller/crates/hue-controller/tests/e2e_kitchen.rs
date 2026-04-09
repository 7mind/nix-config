//! End-to-end tests against an embedded `rumqttd` broker.
//!
//! These spin up a real broker, a real test MQTT client, and the real
//! daemon (`hue_controller::daemon::run`) all in one process. Messages
//! flow over loopback TCP through the broker — same wire format the
//! production daemon would see — so the parser, state machine, and
//! publisher are all exercised end-to-end.
//!
//! The state-machine logic itself is unit-tested in `controller.rs`;
//! these tests cover the layers BELOW the controller: MQTT subscription,
//! topic dispatch, payload parsing, action serialization, and the
//! startup state refresh.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::{TestBroker, TestClient};
use hue_controller::time::FakeClock;

/// Helper: spin up a broker, a publisher client, then a daemon. Returns
/// the broker, the test client, and the shutdown handle for the daemon.
async fn start_kitchen_setup() -> (TestBroker, TestClient, tokio::sync::mpsc::Sender<()>) {
    let broker = TestBroker::start().await;
    let test_client = TestClient::connect(&broker, "test-client").await;

    // Subscribe to every set topic the daemon might publish to BEFORE
    // starting the daemon, so we don't miss any.
    for group in [
        "hue-lz-kitchen-cooker/set",
        "hue-lz-kitchen-dining/set",
        "hue-lz-kitchen-all/set",
    ] {
        test_client
            .subscribe(&format!("zigbee2mqtt/{group}"))
            .await;
    }
    // Also subscribe to /get topics so we can see the daemon's startup
    // refresh chatter (used by one test below).
    for group in ["hue-lz-kitchen-cooker", "hue-lz-kitchen-dining", "hue-lz-kitchen-all"] {
        test_client
            .subscribe(&format!("zigbee2mqtt/{group}/get"))
            .await;
    }
    // Tiny grace so the SUBACKs land before we start firing publishes.
    tokio::time::sleep(Duration::from_millis(50)).await;

    let clock = Arc::new(FakeClock::new(12));
    let cfg = common::fixtures::kitchen_config();
    let shutdown = common::spawn_daemon(cfg, &broker, clock);

    // Wait for the daemon's startup state refresh to complete. Without
    // any retained messages it'll fall through phase 1 (300 ms wait),
    // then publish 3 /get's (3 × 50 ms inter-publish delay), then wait
    // up to 2 s in phase 3 for responses that never come. Total ~2.5 s.
    // Tests don't need to wait the full window — once the /get burst
    // has gone out, the daemon is processing events normally.
    wait_for_count(&test_client, "zigbee2mqtt/hue-lz-kitchen-all/get", 1).await;

    (broker, test_client, shutdown)
}

/// Polling helper used in place of `wait_for(... 1, ...)` when the test
/// just wants to know "has the first message arrived yet?". Faster
/// failure modes than the bigger wait_for.
async fn wait_for_count(client: &TestClient, topic: &str, count: usize) {
    client
        .inbox
        .wait_for(topic, count, Duration::from_secs(5))
        .await;
}

#[tokio::test]
async fn daemon_startup_publishes_get_to_every_group() {
    let broker = TestBroker::start().await;
    let test_client = TestClient::connect(&broker, "test-client-startup").await;

    // Subscribe to /get topics BEFORE starting the daemon so we capture
    // the startup state-refresh burst.
    for group in ["hue-lz-kitchen-cooker", "hue-lz-kitchen-dining", "hue-lz-kitchen-all"] {
        test_client
            .subscribe(&format!("zigbee2mqtt/{group}/get"))
            .await;
    }
    tokio::time::sleep(Duration::from_millis(50)).await;

    let clock = Arc::new(FakeClock::new(12));
    let cfg = common::fixtures::kitchen_config();
    let _shutdown = common::spawn_daemon(cfg, &broker, clock);

    for group in ["hue-lz-kitchen-cooker", "hue-lz-kitchen-dining", "hue-lz-kitchen-all"] {
        wait_for_count(&test_client, &format!("zigbee2mqtt/{group}/get"), 1).await;
    }
}

#[tokio::test]
async fn tap_press_publishes_first_scene() {
    let (_broker, test_client, _shutdown) = start_kitchen_setup().await;

    // Press button 2 (kitchen-cooker) → fresh on, scene 1.
    test_client
        .publish("zigbee2mqtt/hue-ts-foo/action", "press_2")
        .await;

    let msgs = test_client
        .inbox
        .wait_for(
            "zigbee2mqtt/hue-lz-kitchen-cooker/set",
            1,
            Duration::from_secs(3),
        )
        .await;
    let payload: serde_json::Value = serde_json::from_slice(&msgs[0]).unwrap();
    assert_eq!(payload, serde_json::json!({ "scene_recall": 1 }));
}

#[tokio::test]
async fn parent_press_then_child_press_toggles_child_off() {
    // The kitchen-all → kitchen-cooker bug, validated end-to-end through
    // a real broker.
    let (_broker, test_client, _shutdown) = start_kitchen_setup().await;

    // 1. Press button 1 (parent) → fresh on, scene 1 to kitchen-all.
    test_client
        .publish("zigbee2mqtt/hue-ts-foo/action", "press_1")
        .await;
    test_client
        .inbox
        .wait_for(
            "zigbee2mqtt/hue-lz-kitchen-all/set",
            1,
            Duration::from_secs(3),
        )
        .await;

    // 2. Press button 2 (child) → expire path → state OFF on
    //    kitchen-cooker. The child's `physically_on` is true (parent
    //    invalidation propagated it) and `last_press_at` is None (so the
    //    elapsed time is "infinite"), which routes the press into the
    //    expire branch.
    test_client
        .publish("zigbee2mqtt/hue-ts-foo/action", "press_2")
        .await;
    let msgs = test_client
        .inbox
        .wait_for(
            "zigbee2mqtt/hue-lz-kitchen-cooker/set",
            1,
            Duration::from_secs(3),
        )
        .await;
    let payload: serde_json::Value = serde_json::from_slice(&msgs[0]).unwrap();
    let state = payload.get("state").and_then(|v| v.as_str());
    assert_eq!(
        state,
        Some("OFF"),
        "child press after parent on should toggle off, got: {payload}"
    );
}

#[tokio::test]
async fn group_state_off_event_resets_zone_state() {
    // Verify the daemon listens to <group> state topics and updates
    // its internal cache. After we publish state OFF for kitchen-cooker,
    // a fresh button press should take the lights_off path (scene 1)
    // not the expire path.
    let (_broker, test_client, _shutdown) = start_kitchen_setup().await;

    // 1. Press button 2 → cooker on (cooker.physically_on = true).
    test_client
        .publish("zigbee2mqtt/hue-ts-foo/action", "press_2")
        .await;
    test_client
        .inbox
        .wait_for(
            "zigbee2mqtt/hue-lz-kitchen-cooker/set",
            1,
            Duration::from_secs(3),
        )
        .await;

    // 2. Simulate z2m publishing the cooker group state going OFF (e.g.
    //    via the Hue app). The daemon should reset cooker.physically_on
    //    to false.
    test_client
        .publish(
            "zigbee2mqtt/hue-lz-kitchen-cooker",
            r#"{"state":"OFF"}"#,
        )
        .await;
    // Brief wait for the daemon to process the state update.
    tokio::time::sleep(Duration::from_millis(100)).await;

    // 3. Press button 2 again → because cooker is physically off, this
    //    should publish scene_recall:1 (fresh on).
    test_client
        .publish("zigbee2mqtt/hue-ts-foo/action", "press_2")
        .await;
    let msgs = test_client
        .inbox
        .wait_for(
            "zigbee2mqtt/hue-lz-kitchen-cooker/set",
            2,
            Duration::from_secs(3),
        )
        .await;
    let second: serde_json::Value = serde_json::from_slice(&msgs[1]).unwrap();
    assert_eq!(
        second,
        serde_json::json!({ "scene_recall": 1 }),
        "second press after external OFF should be a fresh-on, got: {second}"
    );
}

#[tokio::test]
async fn retained_group_state_seeds_initial_physical_on() {
    // Phase 1 of the startup state refresh consumes retained messages.
    // We seed the broker with a retained "ON" for kitchen-cooker BEFORE
    // starting the daemon, then verify that pressing the cooker button
    // immediately produces an OFF (because cooker.physically_on was set
    // to true at startup).
    let broker = TestBroker::start().await;
    let test_client = TestClient::connect(&broker, "test-client-retained").await;

    // Set up subscriptions on the test client.
    for group in ["hue-lz-kitchen-cooker/set", "hue-lz-kitchen-all/set"] {
        test_client
            .subscribe(&format!("zigbee2mqtt/{group}"))
            .await;
    }
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Seed retained group state.
    test_client
        .publish_retained(
            "zigbee2mqtt/hue-lz-kitchen-cooker",
            r#"{"state":"ON"}"#,
        )
        .await;
    // Tiny pause so the broker definitely persists the retain before
    // the daemon subscribes.
    tokio::time::sleep(Duration::from_millis(50)).await;

    let clock = Arc::new(FakeClock::new(12));
    let cfg = common::fixtures::kitchen_config();
    let _shutdown = common::spawn_daemon(cfg, &broker, clock);

    // Give the daemon a moment to complete its retained-message drain.
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Press cooker → because phase 1 saw the retained ON, the daemon
    // believes cooker is physically on. With last_press_at still None,
    // the press takes the expire branch → publishes state OFF.
    test_client
        .publish("zigbee2mqtt/hue-ts-foo/action", "press_2")
        .await;

    let msgs = test_client
        .inbox
        .wait_for(
            "zigbee2mqtt/hue-lz-kitchen-cooker/set",
            1,
            Duration::from_secs(3),
        )
        .await;
    let payload: serde_json::Value = serde_json::from_slice(&msgs[0]).unwrap();
    assert_eq!(
        payload.get("state").and_then(|v| v.as_str()),
        Some("OFF"),
        "after retained ON seeded the daemon, first press should toggle off"
    );
}

#[tokio::test]
async fn unknown_action_payload_is_silently_ignored() {
    let (_broker, test_client, _shutdown) = start_kitchen_setup().await;

    // Publish a garbage action — daemon should not crash, not publish
    // anything, and a follow-up valid press should still work.
    test_client
        .publish("zigbee2mqtt/hue-ts-foo/action", "press_42")
        .await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    let count = test_client
        .inbox
        .count("zigbee2mqtt/hue-lz-kitchen-cooker/set")
        .await;
    assert_eq!(count, 0, "garbage tap action should not produce any /set");

    // Real press still works.
    test_client
        .publish("zigbee2mqtt/hue-ts-foo/action", "press_2")
        .await;
    test_client
        .inbox
        .wait_for(
            "zigbee2mqtt/hue-lz-kitchen-cooker/set",
            1,
            Duration::from_secs(3),
        )
        .await;
}
