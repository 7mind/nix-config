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

// ---- Z-Wave JS UI topics ------------------------------------------------

/// Z-Wave binary switch state topic:
/// `zwave/<name>/switch_binary/endpoint_0/currentValue`.
/// Payload: `{"time":…,"value":true/false,"nodeName":"…","nodeLocation":"…"}`
pub fn zwave_switch_state_topic(name: &str) -> String {
    format!("zwave/{name}/switch_binary/endpoint_0/currentValue")
}

/// Z-Wave meter power topic (watts):
/// `zwave/<name>/meter/endpoint_0/value/66049`.
/// Payload: `{"time":…,"value":<watts>,"nodeName":"…","nodeLocation":"…"}`
pub fn zwave_meter_power_topic(name: &str) -> String {
    format!("zwave/{name}/meter/endpoint_0/value/{}", super::codec::zwave_meter::POWER_W)
}

/// Z-Wave binary switch command topic:
/// `zwave/<name>/switch_binary/endpoint_0/targetValue/set`.
/// Payload: `true` or `false`.
pub fn zwave_switch_set_topic(name: &str) -> String {
    format!("zwave/{name}/switch_binary/endpoint_0/targetValue/set")
}

/// Z-Wave nodeinfo topic (single-level wildcard for discovery):
/// `zwave/+/nodeinfo`. Used by the provisioner to discover current
/// node names.
pub fn zwave_nodeinfo_wildcard() -> &'static str {
    "zwave/+/nodeinfo"
}

/// Z-Wave JS UI API request topic for setting a node's name:
/// `zwave/_CLIENTS/ZWAVE_GATEWAY-zwave/api/setNodeName/set`.
pub fn zwave_api_set_node_name() -> String {
    format!("{}setNodeName/set", super::codec::zwave_api::GATEWAY_PREFIX)
}

/// Z-Wave JS UI API response topic for setNodeName:
/// `zwave/_CLIENTS/ZWAVE_GATEWAY-zwave/api/setNodeName`.
pub fn zwave_api_set_node_name_response() -> String {
    format!("{}setNodeName", super::codec::zwave_api::GATEWAY_PREFIX)
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
}
