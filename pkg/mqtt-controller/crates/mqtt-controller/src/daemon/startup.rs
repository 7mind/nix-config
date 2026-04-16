//! Startup state refresh: drain retained group state, fall back to
//! `/get` queries, then refresh Z-Wave plug values, TRVs, and wall
//! thermostats. See [`super`] module docs for the full phase breakdown.

use std::collections::BTreeSet;
use std::time::{Duration, Instant};

use tokio::sync::mpsc;

use crate::domain::event::Event;
use crate::logic::EventProcessor;
use crate::mqtt::MqttBridge;
use crate::time::Clock;
use crate::topology::Topology;

use super::DaemonError;

/// Inter-publish gap when bursting `/get` queries to z2m during the
/// startup state refresh. Each /get triggers a zigbee read, so flooding
/// them risks stalling z2m's worker queue.
const GET_BURST_INTERPACKET_DELAY: Duration = Duration::from_millis(50);

/// Three-phase startup state refresh. See module docs.
pub(super) async fn refresh_state(
    processor: &mut EventProcessor,
    bridge: &MqttBridge,
    event_rx: &mut mpsc::Receiver<Event>,
    topology: &Topology,
    clock: &dyn Clock,
) -> Result<(), DaemonError> {
    let all_groups: BTreeSet<String> = topology
        .all_group_names()
        .into_iter()
        .map(String::from)
        .collect();
    let mut seen_groups: BTreeSet<String> = BTreeSet::new();

    // Phase 1: drain retained messages.
    let phase1_window = Duration::from_millis(300);
    let phase1_deadline = clock.now() + phase1_window;
    drain_until(
        processor,
        bridge,
        event_rx,
        &mut seen_groups,
        phase1_deadline,
        all_groups.len(),
        clock,
    )
    .await;
    tracing::info!(
        retained = seen_groups.len(),
        total = all_groups.len(),
        "phase 1: retained-message drain"
    );

    // Phase 2+3: /get missing groups and drain responses.
    let missing: Vec<String> = all_groups.difference(&seen_groups).cloned().collect();
    if !missing.is_empty() {
        tracing::info!(missing = missing.len(), "phase 2: issuing /get for missing groups");
        // Pace the /get publishes so we don't dump all of them on z2m at
        // once. z2m has to walk every member bulb of the group over zigbee
        // to satisfy each /get; back-to-back floods can stall the z2m
        // worker queue. 50 ms between publishes gives a 19-group setup a
        // ~1s burst window which is well below the 2s phase-3 deadline.
        for group in &missing {
            bridge.publish_get(group).await?;
            tokio::time::sleep(GET_BURST_INTERPACKET_DELAY).await;
        }

        // Phase 3: drain /get responses.
        let phase3_window = Duration::from_secs(2);
        let phase3_deadline = clock.now() + phase3_window;
        drain_until(
            processor,
            bridge,
            event_rx,
            &mut seen_groups,
            phase3_deadline,
            all_groups.len(),
            clock,
        )
        .await;

        let still_missing = all_groups.len() - seen_groups.len();
        if still_missing > 0 {
            let names: Vec<&String> = all_groups.difference(&seen_groups).collect();
            tracing::warn!(
                still_missing,
                ?names,
                "phase 3: groups still without state, defaulting to OFF"
            );
        }
    }

    // Phase 3b: Zigbee plug state refresh. Same approach as group
    // /get — ask z2m to re-query each Zigbee plug's state over the air.
    // Without this, Zigbee plugs rely entirely on retained state, and
    // if z2m's retained messages are lost, plugs are stuck at OFF.
    let zigbee_plugs = topology.zigbee_plug_names();
    if !zigbee_plugs.is_empty() {
        tracing::info!(
            zigbee_plugs = zigbee_plugs.len(),
            "phase 3b: refreshing zigbee plug states"
        );
        for plug_name in zigbee_plugs {
            if let Err(e) = bridge.publish_get(plug_name).await {
                tracing::warn!(plug = plug_name.as_str(), error = ?e, "failed to request zigbee plug refresh");
            }
            tokio::time::sleep(GET_BURST_INTERPACKET_DELAY).await;
        }
        let zigbee_plug_drain = Duration::from_secs(2);
        let zigbee_plug_deadline = clock.now() + zigbee_plug_drain;
        // Use usize::MAX so drain runs until deadline — we're waiting
        // for plug events, not groups, so the group-count early exit
        // must not apply.
        drain_until(
            processor,
            bridge,
            event_rx,
            &mut seen_groups,
            zigbee_plug_deadline,
            usize::MAX,
            clock,
        )
        .await;
    }

    // Phase 4: Z-Wave plug state refresh. With retain=false, the
    // daemon has no idea whether Z-Wave plugs are on or off after a
    // restart. Ask the Z-Wave JS UI gateway to re-poll each node's
    // values; the resulting currentValue publishes arrive on the
    // topics we already subscribe to and get processed as PlugState
    // events during the drain window.
    let zwave_map = topology.zwave_node_id_to_name();
    if !zwave_map.is_empty() {
        tracing::info!(
            zwave_plugs = zwave_map.len(),
            "phase 4: refreshing zwave plug states"
        );
        for (&node_id, name) in zwave_map {
            tracing::info!(node_id, name = name.as_str(), "requesting zwave value refresh");
            if let Err(e) = bridge.publish_zwave_refresh(node_id).await {
                tracing::warn!(node_id, error = ?e, "failed to request zwave refresh");
            }
            tokio::time::sleep(GET_BURST_INTERPACKET_DELAY).await;
        }
        // Drain the Z-Wave responses. Same usize::MAX trick — we're
        // waiting for Z-Wave events, not group events.
        let zwave_drain_window = Duration::from_secs(3);
        let zwave_deadline = clock.now() + zwave_drain_window;
        drain_until(
            processor,
            bridge,
            event_rx,
            &mut seen_groups,
            zwave_deadline,
            usize::MAX,
            clock,
        )
        .await;
    }

    // Phase 5: TRV and wall thermostat state refresh. Query each device
    // to populate the heating controller's initial state.
    //
    // TRVs need explicit climate attribute queries (local_temperature,
    // pi_heating_demand, running_state, occupied_heating_setpoint) —
    // the generic {"state":""} doesn't return these on Bosch BTH-RA.
    //
    // Wall thermostats use the standard {"state":""} query which
    // returns the relay on/off state.
    let trv_names = topology.all_trv_names();
    let wt_names = topology.all_wall_thermostat_names();
    if !trv_names.is_empty() || !wt_names.is_empty() {
        tracing::info!(
            trvs = trv_names.len(),
            wall_thermostats = wt_names.len(),
            "phase 5: refreshing heating device states"
        );
        for name in trv_names {
            if let Err(e) = bridge.publish_get_trv(name).await {
                tracing::warn!(
                    device = name.as_str(),
                    error = ?e,
                    "failed to request TRV state refresh"
                );
            }
            tokio::time::sleep(GET_BURST_INTERPACKET_DELAY).await;
        }
        for name in wt_names {
            if let Err(e) = bridge.publish_get(name).await {
                tracing::warn!(
                    device = name.as_str(),
                    error = ?e,
                    "failed to request wall thermostat state refresh"
                );
            }
            tokio::time::sleep(GET_BURST_INTERPACKET_DELAY).await;
        }
        let heating_drain = Duration::from_secs(2);
        let heating_deadline = clock.now() + heating_drain;
        drain_until(
            processor,
            bridge,
            event_rx,
            &mut seen_groups,
            heating_deadline,
            usize::MAX,
            clock,
        )
        .await;
    }

    Ok(())
}

/// Pull events from the channel until either the deadline expires or
/// every group in `expected_total` has been seen. Forwards every event
/// to the controller AND publishes any resulting actions through the
/// bridge — a button press during the startup window must still produce
/// the right physical effect, even though the controller's `physically_on`
/// for some groups may still be defaulted to false. The very next group
/// state event from z2m will reconcile any divergence.
async fn drain_until(
    processor: &mut EventProcessor,
    bridge: &MqttBridge,
    event_rx: &mut mpsc::Receiver<Event>,
    seen_groups: &mut BTreeSet<String>,
    deadline: Instant,
    expected_total: usize,
    clock: &dyn Clock,
) {
    while seen_groups.len() < expected_total {
        let now = clock.now();
        if now >= deadline {
            break;
        }
        let timeout = deadline - now;
        let recv = tokio::time::timeout(timeout, event_rx.recv()).await;
        match recv {
            Ok(Some(event)) => {
                if let Event::GroupState { group, .. } = &event {
                    seen_groups.insert(group.clone());
                }
                let actions = processor.handle_event(event);
                for action in actions {
                    if let Err(e) = bridge.publish_action(&action).await {
                        tracing::error!(
                            error = ?e,
                            "failed to publish action during startup refresh"
                        );
                    }
                }
            }
            Ok(None) => break, // channel closed
            Err(_) => break,    // timeout
        }
    }
}
