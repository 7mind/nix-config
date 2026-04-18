//! Tests for `room`. Split out so `room.rs` stays focused on
//! production code. See `room.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;

#[test]
fn deserialize_minimal_room() {
    let json = r#"{
        "name": "kitchen-cooker",
        "group_name": "hue-lz-kitchen-cooker",
        "id": 15,
        "members": ["hue-l-cooker-bottom/11", "hue-l-cooker-top/11"],
        "parent": "kitchen-all",
        "motion_sensors": ["hue-ms-kitchen"],
        "scenes": {
            "scenes": [
                {"id": 1, "name": "x", "state": "ON", "brightness": null, "color_temp": null, "transition": 0.5}
            ],
            "slots": {
                "day": {"from": "00:00", "to": "24:00", "scene_ids": [1]}
            }
        },
        "off_transition_seconds": 0.8,
        "motion_off_cooldown_seconds": 0
    }"#;
    let room: Room = serde_json::from_str(json).unwrap();
    assert_eq!(room.name, "kitchen-cooker");
    assert_eq!(room.parent.as_deref(), Some("kitchen-all"));
    assert_eq!(room.motion_sensors, vec!["hue-ms-kitchen"]);
    assert_eq!(room.members.len(), 2);
}
