//! Tests for `zwave_server` parsing. The full handshake path needs a
//! real server; integration tests cover it separately. These cover the
//! pure-JSON parsing functions.

use super::*;
use serde_json::json;

fn values_with_switch_and_meter() -> Value {
    json!([
        {"commandClass": 37, "endpoint": 0, "property": "currentValue", "currentValue": true},
        {"commandClass": 50, "endpoint": 0, "property": "value", "propertyKey": 66049, "currentValue": 42.5},
        {"commandClass": 50, "endpoint": 0, "property": "value", "propertyKey": 66561, "currentValue": 230.0}, // voltage, ignored
        {"commandClass": 37, "endpoint": 1, "property": "currentValue", "currentValue": false}  // wrong endpoint
    ])
}

#[test]
fn extract_switch_on_matches_endpoint_0() {
    let vs = values_with_switch_and_meter();
    let arr = vs.as_array().unwrap();
    assert_eq!(extract_switch_on(arr), Some(true));
}

#[test]
fn extract_switch_on_returns_none_when_missing() {
    let vs = json!([
        {"commandClass": 50, "endpoint": 0, "property": "value", "propertyKey": 66049, "currentValue": 0.0}
    ]);
    let arr = vs.as_array().unwrap();
    assert!(extract_switch_on(arr).is_none());
}

#[test]
fn extract_power_w_picks_power_key() {
    let vs = values_with_switch_and_meter();
    let arr = vs.as_array().unwrap();
    assert_eq!(extract_power_w(arr), Some(42.5));
}

#[test]
fn extract_power_w_clamps_negative_to_zero() {
    let vs = json!([
        {"commandClass": 50, "endpoint": 0, "property": "value", "propertyKey": 66049, "currentValue": -3.0}
    ]);
    let arr = vs.as_array().unwrap();
    assert_eq!(extract_power_w(arr), Some(0.0));
}

#[test]
fn parse_node_full_entry() {
    let entry = json!({
        "nodeId": 6,
        "name": "zneo-p-attic-desk",
        "location": "attic",
        "values": values_with_switch_and_meter()
    });
    let n = parse_node(&entry).unwrap();
    assert_eq!(n.node_id, 6);
    assert_eq!(n.current_name, "zneo-p-attic-desk");
    assert_eq!(n.current_location, "attic");
    assert_eq!(n.switch_on, Some(true));
    assert_eq!(n.power_w, Some(42.5));
}

#[test]
fn parse_node_defaults_empty_name_to_node_id_form() {
    let entry = json!({"nodeId": 3, "name": "", "values": []});
    let n = parse_node(&entry).unwrap();
    assert_eq!(n.current_name, "nodeID_3");
    assert_eq!(n.current_location, "");
    assert!(n.switch_on.is_none());
    assert!(n.power_w.is_none());
}

#[test]
fn parse_node_without_id_returns_none() {
    let entry = json!({"name": "nope", "values": []});
    assert!(parse_node(&entry).is_none());
}

#[test]
fn expect_success_validates_envelope() {
    assert!(expect_success(&json!({"type": "result", "messageId": "7", "success": true}), "7").is_ok());
    assert!(expect_success(&json!({"type": "result", "messageId": "7", "success": false, "errorCode": "boom"}), "7").is_err());
    assert!(expect_success(&json!({"type": "result", "messageId": "8", "success": true}), "7").is_err());
    assert!(expect_success(&json!({"type": "event"}), "7").is_err());
}
