//! z2m MQTT topic helpers. Centralized so the bridge, the provisioner, and
//! the topology validator all agree on what a topic looks like.

/// Action topic for a Hue dimmer or Tap: `zigbee2mqtt/<friendly_name>/action`.
pub fn device_action_topic(friendly_name: &str) -> String {
    format!("zigbee2mqtt/{friendly_name}/action")
}

/// State topic for a device or group: `zigbee2mqtt/<friendly_name>`.
/// Same shape for both — z2m publishes the device's full retained state
/// (or the group's aggregated state) to this topic.
pub fn state_topic(friendly_name: &str) -> String {
    format!("zigbee2mqtt/{friendly_name}")
}

/// Set topic for sending commands: `zigbee2mqtt/<friendly_name>/set`.
pub fn set_topic(friendly_name: &str) -> String {
    format!("zigbee2mqtt/{friendly_name}/set")
}

/// "Get" topic for active state queries:
/// `zigbee2mqtt/<friendly_name>/get`. Publishing `{"state": ""}` here
/// makes z2m fetch the current state from the device(s) and publish on
/// the matching state topic.
pub fn get_topic(friendly_name: &str) -> String {
    format!("zigbee2mqtt/{friendly_name}/get")
}

#[cfg(test)]
mod tests {
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
}
