//! End-to-end tests exercising TASS-specific state machine scenarios.
//!
//! These tests validate target/actual state separation, motion ownership
//! tracking, and parent-child propagation through the full daemon stack
//! (embedded broker + real MQTT + EventProcessor).

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::{TestBroker, TestClient};
use mqtt_controller::time::FakeClock;

// ---------------------------------------------------------------------------
// Setup helpers
// ---------------------------------------------------------------------------

/// Spin up a broker, test client, and daemon using the kitchen config
/// (no motion sensors). Returns the broker, client, and shutdown handle.
async fn start_kitchen_setup() -> (TestBroker, TestClient, tokio::sync::mpsc::Sender<()>) {
    let broker = TestBroker::start().await;
    let test_client = TestClient::connect(&broker, "test-client").await;

    for group in [
        "hue-lz-kitchen-cooker/set",
        "hue-lz-kitchen-dining/set",
        "hue-lz-kitchen-all/set",
    ] {
        test_client
            .subscribe(&format!("zigbee2mqtt/{group}"))
            .await;
    }
    tokio::time::sleep(Duration::from_millis(50)).await;

    let clock = Arc::new(FakeClock::new(12));
    let cfg = common::fixtures::kitchen_config();
    let shutdown = common::spawn_daemon(cfg, &broker, clock);

    // Let the daemon's wildcard SUBSCRIBE round-trip complete.
    tokio::time::sleep(Duration::from_millis(200)).await;

    (broker, test_client, shutdown)
}

/// Spin up a broker, test client, and daemon using the kitchen config
/// WITH a motion sensor on kitchen-cooker. Subscribes to the cooker /set
/// topic and waits for the daemon's startup /get burst.
async fn start_kitchen_with_motion_setup() -> (TestBroker, TestClient, tokio::sync::mpsc::Sender<()>) {
    let broker = TestBroker::start().await;
    let test_client = TestClient::connect(&broker, "test-client").await;

    for group in [
        "hue-lz-kitchen-cooker/set",
        "hue-lz-kitchen-dining/set",
        "hue-lz-kitchen-all/set",
    ] {
        test_client
            .subscribe(&format!("zigbee2mqtt/{group}"))
            .await;
    }
    tokio::time::sleep(Duration::from_millis(50)).await;

    let clock = Arc::new(FakeClock::new(12));
    let cfg = common::fixtures::kitchen_with_motion_config();
    let shutdown = common::spawn_daemon(cfg, &broker, clock);

    // Let the daemon's wildcard SUBSCRIBE round-trip complete.
    tokio::time::sleep(Duration::from_millis(200)).await;

    (broker, test_client, shutdown)
}

/// Spin up a broker, test client, and daemon using the Sonoff bedroom
/// config (SceneToggle on Press, SceneCycle on DoubleTap). Used for
/// double-tap suppression regression tests. Returns the clock handle
/// so tests can advance it for deferred press flushing.
async fn start_bedroom_sonoff_setup() -> (TestBroker, TestClient, tokio::sync::mpsc::Sender<()>, Arc<FakeClock>) {
    let broker = TestBroker::start().await;
    let test_client = TestClient::connect(&broker, "test-client").await;

    test_client
        .subscribe("zigbee2mqtt/hue-lz-bedroom/set")
        .await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    let clock = Arc::new(FakeClock::new(12));
    let cfg = common::fixtures::kitchen_with_sonoff_config();
    let shutdown = common::spawn_daemon(cfg, &broker, clock.clone());

    // Let the daemon's wildcard SUBSCRIBE round-trip complete.
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Seed the room's actual state as OFF so the daemon knows it and
    // can_early_fire_press works (requires actual.is_known()).
    test_client
        .publish("zigbee2mqtt/hue-lz-bedroom", r#"{"state":"OFF"}"#)
        .await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    (broker, test_client, shutdown, clock)
}

async fn wait_for_count(client: &TestClient, topic: &str, count: usize) {
    client
        .inbox
        .wait_for(topic, count, Duration::from_secs(5))
        .await;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Test that TASS target phase transitions to Confirmed after z2m echo.
///
/// 1. Press button -> scene_recall published (target = Commanded)
/// 2. Publish group state ON (simulating z2m echo) -> target = Confirmed
/// 3. Press button again -> should cycle (not fresh-on), confirming
///    internal state correctly tracks the zone as ON.
/// 4. Verify the second press produces scene_recall:2 (cycle advance).
#[tokio::test]
async fn target_confirmed_after_echo() {
    let (_broker, test_client, _shutdown) = start_kitchen_setup().await;

    // 1. Press button 2 (kitchen-cooker) -> fresh on, scene 1.
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
    let first: serde_json::Value = serde_json::from_slice(&msgs[0]).unwrap();
    assert_eq!(
        first,
        serde_json::json!({ "scene_recall": 1 }),
        "first press should be fresh-on scene 1"
    );

    // 2. Publish z2m echo: group state ON. This transitions the target
    //    phase from Commanded to Confirmed, and updates actual to On.
    test_client
        .publish(
            "zigbee2mqtt/hue-lz-kitchen-cooker",
            r#"{"state":"ON"}"#,
        )
        .await;
    tokio::time::sleep(Duration::from_millis(100)).await;

    // 3. Press button 2 again. Zone is on (both target and actual agree),
    //    and we're within the cycle window, so this should cycle-advance
    //    to scene 2.
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
        serde_json::json!({ "scene_recall": 2 }),
        "second press after z2m echo should cycle to scene 2, got: {second}"
    );
}

/// Test motion ownership tracking: motion-off turns lights off, and a
/// subsequent motion-on re-trigger works immediately (no cooldown since
/// motion_off_cooldown_seconds is 0 in the fixture).
///
/// 1. Publish motion ON (occupancy:true) -> lights turn on (motion-owned)
/// 2. Publish motion OFF (occupancy:false) -> lights turn off
/// 3. Immediately publish motion ON again -> should turn on again
/// 4. Verify scene_recall published for the re-trigger
#[tokio::test]
async fn motion_owner_prevents_user_off_from_motion_retrigger() {
    let (_broker, test_client, _shutdown) = start_kitchen_with_motion_setup().await;

    // 1. Motion ON -> scene_recall:1 (motion-owned, room was off).
    test_client
        .publish(
            "zigbee2mqtt/hue-ms-kitchen",
            r#"{"occupancy":true,"illuminance":10}"#,
        )
        .await;
    let msgs = test_client
        .inbox
        .wait_for(
            "zigbee2mqtt/hue-lz-kitchen-cooker/set",
            1,
            Duration::from_secs(3),
        )
        .await;
    let first: serde_json::Value = serde_json::from_slice(&msgs[0]).unwrap();
    assert_eq!(
        first,
        serde_json::json!({ "scene_recall": 1 }),
        "motion-on should publish scene_recall:1"
    );

    // 2. Motion OFF -> state OFF (motion-owned, all sensors clear).
    test_client
        .publish(
            "zigbee2mqtt/hue-ms-kitchen",
            r#"{"occupancy":false}"#,
        )
        .await;
    let msgs = test_client
        .inbox
        .wait_for(
            "zigbee2mqtt/hue-lz-kitchen-cooker/set",
            2,
            Duration::from_secs(3),
        )
        .await;
    let off_payload: serde_json::Value = serde_json::from_slice(&msgs[1]).unwrap();
    let state = off_payload.get("state").and_then(|v| v.as_str());
    assert_eq!(
        state,
        Some("OFF"),
        "motion-off should publish state OFF, got: {off_payload}"
    );

    // 3. Motion ON again immediately -> scene_recall:1 (no cooldown).
    test_client
        .publish(
            "zigbee2mqtt/hue-ms-kitchen",
            r#"{"occupancy":true,"illuminance":10}"#,
        )
        .await;
    let msgs = test_client
        .inbox
        .wait_for(
            "zigbee2mqtt/hue-lz-kitchen-cooker/set",
            3,
            Duration::from_secs(3),
        )
        .await;
    let retrigger: serde_json::Value = serde_json::from_slice(&msgs[2]).unwrap();
    assert_eq!(
        retrigger,
        serde_json::json!({ "scene_recall": 1 }),
        "motion re-trigger should publish scene_recall:1, got: {retrigger}"
    );
}

/// Test that user press takes priority over motion ownership.
///
/// 1. Motion ON -> lights on (motion-owned)
/// 2. Before motion OFF, press button -> lights stay on, now user-owned
/// 3. Motion OFF -> lights should NOT turn off (user-owned, not motion)
/// 4. Verify no OFF action is published after motion clears
#[tokio::test]
async fn concurrent_button_and_motion_user_wins() {
    let (_broker, test_client, _shutdown) = start_kitchen_with_motion_setup().await;

    // 1. Motion ON -> scene_recall:1 (motion-owned).
    test_client
        .publish(
            "zigbee2mqtt/hue-ms-kitchen",
            r#"{"occupancy":true,"illuminance":10}"#,
        )
        .await;
    let msgs = test_client
        .inbox
        .wait_for(
            "zigbee2mqtt/hue-lz-kitchen-cooker/set",
            1,
            Duration::from_secs(3),
        )
        .await;
    let motion_on: serde_json::Value = serde_json::from_slice(&msgs[0]).unwrap();
    assert_eq!(
        motion_on,
        serde_json::json!({ "scene_recall": 1 }),
        "motion-on should produce scene_recall:1"
    );

    // 2. User presses button 2 while lights are already on (motion-owned).
    //    No prior user press exists (last_press_at is None), so the
    //    scene_toggle_cycle binding takes the "expire" branch → toggle OFF.
    //    This clears motion ownership (Owner::User now owns the Off target).
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
    let user_press: serde_json::Value = serde_json::from_slice(&msgs[1]).unwrap();
    assert_eq!(
        user_press,
        serde_json::json!({ "state": "OFF", "transition": 0.8 }),
        "user press with no prior press should toggle off, got: {user_press}"
    );

    // 3. Motion OFF arrives. Since the zone is now user-owned (not motion),
    //    the motion-off handler should suppress the OFF and NOT publish.
    test_client
        .publish(
            "zigbee2mqtt/hue-ms-kitchen",
            r#"{"occupancy":false}"#,
        )
        .await;

    // Wait long enough to be confident no message arrives.
    tokio::time::sleep(Duration::from_millis(300)).await;

    let count = test_client
        .inbox
        .count("zigbee2mqtt/hue-lz-kitchen-cooker/set")
        .await;
    assert_eq!(
        count, 2,
        "motion-off after user press should NOT publish OFF (count should stay at 2, got {count})"
    );
}

/// Test that stale/unknown actual state does not prevent target setting.
///
/// 1. Don't publish any group state (actual stays Unknown)
/// 2. Press button -> scene_recall:1 should publish (target-based decision)
/// 3. Press button again -> should cycle (target says On, even without actual)
/// 4. Verify scene_recall:2 published
#[tokio::test]
async fn stale_actual_does_not_block_commands() {
    let (_broker, test_client, _shutdown) = start_kitchen_setup().await;

    // 1. Press button 2 with no prior group state. The zone's actual is
    //    Unknown, but is_on() is false (neither target nor actual say On),
    //    so this takes the fresh-on branch.
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
    let first: serde_json::Value = serde_json::from_slice(&msgs[0]).unwrap();
    assert_eq!(
        first,
        serde_json::json!({ "scene_recall": 1 }),
        "first press with unknown actual should produce scene 1"
    );

    // 2. Press again immediately (no z2m echo, actual still Unknown).
    //    But target is On (Commanded), so is_on() returns true, and we're
    //    within the cycle window -> cycle advance to scene 2.
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
        serde_json::json!({ "scene_recall": 2 }),
        "second press without z2m echo should cycle to scene 2, got: {second}"
    );
}

/// Test parent-on propagation to child actual state.
///
/// 1. Press parent button (kitchen-all, button 1) -> all zones go on
/// 2. Verify scene_recall published on parent group
/// 3. Press child button (kitchen-cooker, button 2) -> child is "on" via
///    propagation, and last_press_at is None (propagation clears it), so
///    the elapsed time is "infinite" -> takes the expire branch -> OFF
/// 4. Verify state OFF published for child
#[tokio::test]
async fn parent_on_propagates_to_children_actual() {
    let (_broker, test_client, _shutdown) = start_kitchen_setup().await;

    // 1. Press button 1 (parent: kitchen-all) -> fresh on, scene 1.
    test_client
        .publish("zigbee2mqtt/hue-ts-foo/action", "press_1")
        .await;
    let msgs = test_client
        .inbox
        .wait_for(
            "zigbee2mqtt/hue-lz-kitchen-all/set",
            1,
            Duration::from_secs(3),
        )
        .await;
    let parent_on: serde_json::Value = serde_json::from_slice(&msgs[0]).unwrap();
    assert_eq!(
        parent_on,
        serde_json::json!({ "scene_recall": 1 }),
        "parent press should produce scene_recall:1 on parent group"
    );

    // 2. Press button 2 (child: kitchen-cooker). The child's target is
    //    On (propagated from parent) with last_press_at = None, so the
    //    cycle window check sees "infinite" elapsed time -> expire branch
    //    -> publishes state OFF.
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
    let child_off: serde_json::Value = serde_json::from_slice(&msgs[0]).unwrap();
    let state = child_off.get("state").and_then(|v| v.as_str());
    assert_eq!(
        state,
        Some("OFF"),
        "child press after parent on should toggle off (expire branch), got: {child_off}"
    );
}

/// Regression: parent group OFF echo must clear child target so the
/// child's is_on() returns false. Without this, a stale target=On
/// from a prior child activation makes the next child press take the
/// wrong branch.
///
/// The parent must first be seen as ON (via echo) so the OFF echo
/// triggers a real on→off transition with soft propagation.
#[tokio::test]
async fn parent_off_echo_clears_child_target() {
    let (_broker, test_client, _shutdown) = start_kitchen_setup().await;

    // 1. Press child button (cooker, btn 2) → scene_recall:1.
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

    // 2. Simulate z2m reporting parent group as ON (z2m aggregates
    //    member states into the parent group's retained message).
    test_client
        .publish(
            "zigbee2mqtt/hue-lz-kitchen-all",
            r#"{"state":"ON"}"#,
        )
        .await;
    tokio::time::sleep(Duration::from_millis(100)).await;

    // 3. Parent group OFF echo arrives (e.g., user turns off via z2m GUI).
    //    The daemon detects on→off transition and soft-propagates to
    //    children, clearing the child's stale target.
    test_client
        .publish(
            "zigbee2mqtt/hue-lz-kitchen-all",
            r#"{"state":"OFF"}"#,
        )
        .await;
    tokio::time::sleep(Duration::from_millis(100)).await;

    // 4. Press child button again. Because parent OFF cleared the
    //    child's target+actual, is_on() is false → fresh-on → scene 1.
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
        "child press after parent OFF echo should be fresh-on (scene 1), got: {second}"
    );
}

/// Regression: parent ON propagation must clear child's stale motion
/// ownership so a subsequent motion-off doesn't turn the child back off.
#[tokio::test]
async fn parent_on_clears_child_motion_ownership() {
    let (_broker, test_client, _shutdown) = start_kitchen_with_motion_setup().await;

    // 1. Motion turns on child (cooker) → motion-owned.
    test_client
        .publish(
            "zigbee2mqtt/hue-ms-kitchen",
            r#"{"occupancy":true,"illuminance":10}"#,
        )
        .await;
    test_client
        .inbox
        .wait_for(
            "zigbee2mqtt/hue-lz-kitchen-cooker/set",
            1,
            Duration::from_secs(3),
        )
        .await;

    // 2. User presses parent on (kitchen-all, btn 1). This propagates
    //    to child with Owner::System, overriding motion ownership.
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

    // 3. Motion OFF arrives. Because parent propagation cleared motion
    //    ownership on the child, this should NOT turn the child off.
    test_client
        .publish(
            "zigbee2mqtt/hue-ms-kitchen",
            r#"{"occupancy":false}"#,
        )
        .await;

    tokio::time::sleep(Duration::from_millis(300)).await;

    // Verify no OFF was published for the child.
    let count = test_client
        .inbox
        .count("zigbee2mqtt/hue-lz-kitchen-cooker/set")
        .await;
    assert_eq!(
        count, 1,
        "motion-off after parent press should NOT turn child off (count should stay at 1, got {count})"
    );
}

/// Verify that a parent OFF echo without prior ON does NOT clear a child
/// that was independently activated. In z2m, activating a child group
/// does not activate the parent group, so the parent OFF echo is a
/// non-event — the child's state should be preserved.
#[tokio::test]
async fn parent_off_without_prior_on_preserves_child() {
    let (_broker, test_client, _shutdown) = start_kitchen_setup().await;

    // 1. Press child button (cooker, btn 2) → scene_recall:1.
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

    // 2. Parent OFF echo arrives WITHOUT any prior parent ON echo.
    //    This is a non-event: parent was never ON, child was activated
    //    independently. Child state must NOT be cleared.
    test_client
        .publish(
            "zigbee2mqtt/hue-lz-kitchen-all",
            r#"{"state":"OFF"}"#,
        )
        .await;
    tokio::time::sleep(Duration::from_millis(100)).await;

    // 3. Press child button again. Child is still on (target=On from
    //    step 1, parent OFF didn't clear it). last_press_at is still
    //    within cycle window (~200ms < 2s) → cycles to scene 2.
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
    // Child is still on, within cycle window → cycle advance to scene 2
    // (NOT scene 1 which would mean the parent OFF erroneously cleared child)
    assert_eq!(
        second,
        serde_json::json!({ "scene_recall": 2 }),
        "child should still be on after parent OFF (no prior ON), got: {second}"
    );
}

/// Regression: early-fired double-tap must NOT record last_double_tap,
/// so subsequent single-press events are not suppressed.
///
/// Scenario:
/// 1. Room OFF → double-tap → Press early-fires (turns ON), DoubleTap suppressed
/// 2. Immediately single-click → should turn OFF (SceneToggle)
/// 3. Previously: single-click was suppressed for 2s because last_double_tap was recorded
///
/// Uses multi_thread runtime because the deferred press deferral window
/// flush relies on the daemon's tick loop. With FakeClock, the daemon
/// spins when the OS-time deadline is in the past; multi-thread ensures
/// the test thread can advance the FakeClock to unblock the flush.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn early_fired_double_tap_does_not_suppress_subsequent_press() {
    let (_broker, test_client, _shutdown, clock) = start_bedroom_sonoff_setup().await;

    // 1. Double-tap from OFF: Sonoff sends single_button_1 then double_button_1.
    //    The Press early-fires (room OFF → SceneToggle → ON).
    //    The DoubleTap is suppressed (already_fired).
    test_client
        .publish("zigbee2mqtt/sonoff-ts-bedroom/action", "single_button_1")
        .await;
    let msgs = test_client
        .inbox
        .wait_for("zigbee2mqtt/hue-lz-bedroom/set", 1, Duration::from_secs(3))
        .await;
    let first: serde_json::Value = serde_json::from_slice(&msgs[0]).unwrap();
    assert_eq!(
        first,
        serde_json::json!({"scene_recall": 1}),
        "early-fired press should turn on with scene 1"
    );

    // DoubleTap arrives — should be suppressed (already_fired).
    test_client
        .publish("zigbee2mqtt/sonoff-ts-bedroom/action", "double_button_1")
        .await;
    tokio::time::sleep(Duration::from_millis(100)).await;

    // Confirm no additional action from DoubleTap.
    let count = test_client.inbox.count("zigbee2mqtt/hue-lz-bedroom/set").await;
    assert_eq!(count, 1, "DoubleTap should be suppressed (already_fired)");

    // 2. Immediately single-click to turn off.
    //    Previously this was suppressed by double_tap_suppression.
    //    After fix: last_double_tap was NOT recorded, so Press is not suppressed.
    test_client
        .publish("zigbee2mqtt/sonoff-ts-bedroom/action", "single_button_1")
        .await;

    // Give the daemon a moment to receive and defer the press before
    // advancing the clock past the 0.8s deferral window.
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Advance the FakeClock past the 0.8s deferral window so the daemon's
    // tick handler can flush the deferred press. The daemon's sleep uses
    // OS Instant for wakeup but flush_pending_presses checks against
    // clock.now(), so we must advance the FakeClock.
    clock.advance(Duration::from_secs(1));

    let msgs = test_client
        .inbox
        .wait_for("zigbee2mqtt/hue-lz-bedroom/set", 2, Duration::from_secs(3))
        .await;
    let second: serde_json::Value = serde_json::from_slice(&msgs[1]).unwrap();
    // Room is ON (from step 1). The new Press is deferred 0.8s (room ON →
    // can_early_fire_press returns false). After 0.8s flush: SceneToggle →
    // ON → OFF.
    let state = second.get("state").and_then(|v| v.as_str());
    assert_eq!(
        state,
        Some("OFF"),
        "single-click after early-fired double-tap should NOT be suppressed; got: {second}"
    );
}
