//! Tests for `topics`. Split out so `topics.rs` stays focused on
//! production code. See `topics.rs` for the corresponding `mod tests;`
//! stub with the `#[path]` attribute.

use super::*;

#[test]
fn topic_helpers() {
    assert_eq!(
        device_action_topic("hue-s-mid-bedroom"),
        "zigbee2mqtt/hue-s-mid-bedroom/action"
    );
    assert_eq!(state_topic("hue-lz-kitchen"), "zigbee2mqtt/hue-lz-kitchen");
    assert_eq!(
        set_topic("hue-lz-kitchen"),
        "zigbee2mqtt/hue-lz-kitchen/set"
    );
    assert_eq!(
        get_topic("hue-lz-kitchen"),
        "zigbee2mqtt/hue-lz-kitchen/get"
    );
}

#[test]
fn zwave_topic_helpers() {
    assert_eq!(
        zwave_switch_state_topic("zneo-p-attic-desk"),
        "zwave/zneo-p-attic-desk/switch_binary/endpoint_0/currentValue"
    );
    assert_eq!(
        zwave_meter_power_topic("zneo-p-attic-desk"),
        "zwave/zneo-p-attic-desk/meter/endpoint_0/value/66049"
    );
    assert_eq!(
        zwave_switch_set_topic("zneo-p-attic-desk"),
        "zwave/zneo-p-attic-desk/switch_binary/endpoint_0/targetValue/set"
    );
}
