//! Z-Wave state seed: prime `WorldState.plugs` for every known z-wave
//! plug from Z-Wave JS UI's cached `getNodes` response.
//!
//! Replaces the old per-node `refreshValues` radio-poll phase. One MQTT
//! round-trip returns every node's cached switch/power values, so we
//! can build up TASS state instantly — even for sleeping or currently
//! unresponsive nodes. Ongoing updates still flow in through the
//! daemon's `zwave/#` wildcard subscription.
//!
//! If the seed fails (gateway offline, timeout), the daemon continues
//! with no z-wave plug state; real publishes during normal operation
//! eventually populate it.
//!
//! Any effects produced by the seeded `Event::PlugState` events are
//! discarded — at seed time the kill-switch state machine only arms
//! (with `since = now`), which can't fire a turn-off action within the
//! same tick.

use std::time::Duration;

use crate::domain::event::Event;
use crate::logic::EventProcessor;
use crate::mqtt::zwave_api::ZwaveApiClient;
use crate::mqtt::MqttConfig;
use crate::time::Clock;
use crate::topology::Topology;

/// Seed per-plug actual state for every known Z-Wave plug. Returns the
/// number of plugs successfully seeded.
pub async fn seed_zwave_state(
    processor: &mut EventProcessor,
    mqtt_config: &MqttConfig,
    topology: &Topology,
    clock: &dyn Clock,
    timeout: Duration,
) -> anyhow::Result<usize> {
    let zwave_plugs = topology.zwave_node_id_to_name();
    if zwave_plugs.is_empty() {
        return Ok(0);
    }

    tracing::info!(
        zwave_plugs = zwave_plugs.len(),
        "zwave seed: calling getNodes for bulk state fetch"
    );
    let mut client = ZwaveApiClient::connect(mqtt_config, timeout).await?;
    let nodes = client.get_nodes(timeout).await?;
    client.disconnect().await;

    let now = clock.now();
    let mut seeded = 0;
    for node in nodes {
        let Some(&plug_name) = zwave_plugs.get(&node.node_id) else {
            // Node known to ZJS-UI but not in our catalog — ignore.
            continue;
        };
        let Some(on) = node.switch_on else {
            tracing::info!(
                node_id = node.node_id,
                device = plug_name,
                "zwave seed: no cached switch_binary; skipping (first real publish will populate)"
            );
            continue;
        };
        tracing::info!(
            node_id = node.node_id,
            device = plug_name,
            on,
            power = ?node.power_w,
            "zwave seed: priming plug actual state"
        );
        // Route through the standard PlugState handler so entity
        // accounting (freshness, arm_kill_switch_rules) runs uniformly.
        let _ = processor.handle_event(Event::PlugState {
            device: plug_name.to_string(),
            on,
            power: node.power_w,
            ts: now,
        });
        seeded += 1;
    }
    Ok(seeded)
}
