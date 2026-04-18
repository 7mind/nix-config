//! Tests for `zwave_api`. Split out so `zwave_api.rs` stays focused on
//! production code. See `zwave_api.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;

#[test]
fn parse_get_nodes_success_with_values() {
    let payload = br#"{
        "success": true,
        "message": "Success",
        "result": [
            {
                "id": 1,
                "name": "",
                "loc": "",
                "values": {}
            },
            {
                "id": 6,
                "name": "zneo-p-attic-desk",
                "loc": "attic",
                "values": {
                    "0-37-0-currentValue": {"value": true},
                    "0-50-0-value-66049": {"value": 42.5},
                    "0-50-0-value-66561": {"value": 230.0}
                }
            },
            {
                "id": 7,
                "name": "zneo-p-sleeper",
                "loc": "",
                "values": {
                    "0-37-0-currentValue": {"value": false}
                }
            }
        ]
    }"#;
    let nodes = parse_get_nodes_response(payload).unwrap();
    assert_eq!(nodes.len(), 3);

    assert_eq!(nodes[0].node_id, 1);
    assert_eq!(nodes[0].current_name, "nodeID_1");
    assert!(nodes[0].switch_on.is_none());
    assert!(nodes[0].power_w.is_none());

    assert_eq!(nodes[1].node_id, 6);
    assert_eq!(nodes[1].current_name, "zneo-p-attic-desk");
    assert_eq!(nodes[1].current_location, "attic");
    assert_eq!(nodes[1].switch_on, Some(true));
    assert_eq!(nodes[1].power_w, Some(42.5));

    assert_eq!(nodes[2].switch_on, Some(false));
    assert!(nodes[2].power_w.is_none());
}

#[test]
fn parse_get_nodes_negative_power_clamped() {
    let payload = br#"{
        "success": true,
        "result": [
            {
                "id": 6,
                "name": "p",
                "loc": "",
                "values": {
                    "0-37-0-currentValue": {"value": true},
                    "0-50-0-value-66049": {"value": -5.0}
                }
            }
        ]
    }"#;
    let nodes = parse_get_nodes_response(payload).unwrap();
    assert_eq!(nodes[0].power_w, Some(0.0));
}

#[test]
fn parse_get_nodes_failure() {
    let payload = br#"{"success": false, "message": "gateway offline"}"#;
    let err = parse_get_nodes_response(payload).unwrap_err();
    assert!(err.to_string().contains("gateway offline"));
}

#[test]
fn parse_get_nodes_empty() {
    let payload = br#"{"success": true, "result": []}"#;
    let nodes = parse_get_nodes_response(payload).unwrap();
    assert!(nodes.is_empty());
}
