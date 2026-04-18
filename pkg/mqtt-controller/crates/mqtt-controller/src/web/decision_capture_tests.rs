//! Tests for `decision_capture`. Split out so `decision_capture.rs` stays focused on
//! production code. See `decision_capture.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;

#[test]
fn captures_info_events_when_active() {
    // Install subscriber with our layer (only for this test thread).
    let _guard = tracing_subscriber::registry()
        .with(DecisionCaptureLayer)
        .set_default();

    // Not capturing yet — events are discarded.
    tracing::info!(target: "mqtt_controller::controller", "should be ignored");
    let before = drain_capture();
    assert!(before.is_empty());

    // Start capturing.
    start_capture();
    tracing::info!(target: "mqtt_controller::controller", room = "kitchen", "motion on");
    tracing::info!(target: "mqtt_controller::controller", "scene recall");
    tracing::debug!(target: "mqtt_controller::controller", "debug is filtered");
    tracing::info!(target: "other_crate", "wrong target");
    let captured = drain_capture();

    assert_eq!(captured.len(), 2);
    assert!(captured[0].contains("motion on"));
    assert!(captured[0].contains("room=kitchen"));
    assert!(captured[1].contains("scene recall"));
}

#[test]
fn drain_stops_capturing() {
    let _guard = tracing_subscriber::registry()
        .with(DecisionCaptureLayer)
        .set_default();

    start_capture();
    tracing::info!(target: "mqtt_controller::controller", "first");
    let _ = drain_capture();

    // After drain, capturing is off.
    tracing::info!(target: "mqtt_controller::controller", "second");
    let captured = drain_capture();
    assert!(captured.is_empty());
}
