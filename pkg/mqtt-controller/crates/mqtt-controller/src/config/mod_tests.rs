//! Tests for `mod`. Split out so `mod.rs` stays focused on
//! production code. See `mod.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;

#[test]
fn empty_room_list_parses() {
    let cfg: Config = serde_json::from_str(
        r#"{
            "rooms": []
        }"#,
    )
    .unwrap();
    assert!(cfg.rooms.is_empty());
    assert!(cfg.devices.is_empty());
    assert!(cfg.name_by_address.is_empty());
    assert!(cfg.switch_models.is_empty());
    assert!(cfg.bindings.is_empty());
}

#[test]
fn unknown_top_level_field_is_rejected() {
    let err: Result<Config, _> = serde_json::from_str(
        r#"{
            "rooms": [],
            "ghost_field": 42
        }"#,
    );
    assert!(err.is_err(), "deny_unknown_fields should reject ghost_field");
}
