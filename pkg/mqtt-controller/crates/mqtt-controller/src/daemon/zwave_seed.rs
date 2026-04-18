//! Z-Wave state seed: prime `WorldState.plugs` for every known z-wave
//! plug from `zwave-js-server`'s `start_listening` response. One plain
//! WebSocket round-trip; no MQTT.
//!
//! ZJS-UI embeds `zwave-js-server` on a separate port (default 3000).
//! The server returns the complete driver state including every node's
//! current values — the same data the MQTT `getNodes` call used to
//! give us, but via a dedicated protocol that doesn't require running
//! a second MQTT client at startup.
//!
//! Seed failure is non-fatal: the daemon logs and continues. The
//! wildcard `zwave/#` MQTT subscription is already active, so any
//! future publish will populate the missing state.
//!
//! Any effects produced by the seeded `Event::PlugState` events are
//! discarded — at seed time the kill-switch state machine only arms
//! (with `since = now`), which can't fire a turn-off action within the
//! same tick.

use std::time::Duration;

use crate::domain::event::Event;
use crate::logic::EventProcessor;
use crate::time::Clock;
use crate::topology::Topology;

use super::zwave_server;

/// Seed per-plug actual state for every known Z-Wave plug. Returns the
/// number of plugs successfully seeded.
pub async fn seed_zwave_state(
    processor: &mut EventProcessor,
    ws_url: &str,
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
        ws_url,
        "zwave seed: calling zwave-js-server start_listening"
    );
    let nodes = zwave_server::fetch_nodes(ws_url, timeout).await?;

    let now = clock.now();
    let mut seeded = 0;
    for node in nodes {
        let Some(&plug_name) = zwave_plugs.get(&node.node_id) else {
            // Node known to zwave-js-server but not in our catalog — ignore.
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
