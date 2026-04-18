//! Tests for `action`. Split out so `action.rs` stays focused on
//! production code. See `action.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;
use pretty_assertions::assert_eq;

#[test]
fn scene_recall_serializes_to_z2m_shape() {
    let p = Payload::scene_recall(1);
    let json = serde_json::to_string(&p).unwrap();
    assert_eq!(json, r#"{"scene_recall":1}"#);
}

#[test]
fn state_off_serializes_with_uppercase_state() {
    let p = Payload::state_off(0.8);
    let json = serde_json::to_string(&p).unwrap();
    assert_eq!(json, r#"{"state":"OFF","transition":0.8}"#);
}

#[test]
fn brightness_step_serializes_negative() {
    let p = Payload::brightness_step(-25, 0.2);
    let json = serde_json::to_string(&p).unwrap();
    assert_eq!(json, r#"{"brightness_step":-25,"transition":0.2}"#);
}

#[test]
fn brightness_move_zero_stops_move() {
    let p = Payload::brightness_move(0);
    let json = serde_json::to_string(&p).unwrap();
    assert_eq!(json, r#"{"brightness_move":0}"#);
}

#[test]
fn device_state_on_serializes() {
    let p = Payload::device_on();
    let json = serde_json::to_string(&p).unwrap();
    assert_eq!(json, r#"{"state":"ON"}"#);
}

#[test]
fn device_state_off_serializes() {
    let p = Payload::device_off();
    let json = serde_json::to_string(&p).unwrap();
    assert_eq!(json, r#"{"state":"OFF"}"#);
}
