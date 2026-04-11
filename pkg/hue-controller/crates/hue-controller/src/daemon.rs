//! The runtime daemon: wires the [`MqttBridge`] to the [`Controller`],
//! performs the startup state refresh, then runs the event loop until
//! shutdown.
//!
//! ## Startup state refresh
//!
//! Before the daemon starts processing events, it needs every zone's
//! `physically_on` to reflect physical reality. The bento-era stack
//! couldn't do this — its in-memory cache was wiped on every restart and
//! the controller had no way to ask z2m "what's on right now". The new
//! daemon does it in three phases:
//!
//!   1. **Subscribe phase.** [`MqttBridge::start`] subscribes to every
//!      group's state topic with QoS 1. mosquitto delivers retained
//!      messages immediately on subscribe — z2m publishes group state
//!      with `retain=true` on every change, so any group that has *ever*
//!      had a state change since the last retain clear will report
//!      within tens of milliseconds.
//!
//!   2. **Active query phase.** After a brief grace window collecting
//!      retained messages, the daemon publishes `{"state": ""}` to
//!      `<group>/get` for any group that did not report. z2m issues a
//!      fresh zigbee read against the group's bulbs and publishes the
//!      result on the matching state topic.
//!
//!   3. **Drain phase.** A second grace window collects the `/get`
//!      responses. Any group that *still* doesn't report state is left
//!      with `physically_on = false` (the safe assumption — the next
//!      real state message will correct it).
//!
//! Total worst-case startup latency: grace_phase_1 + grace_phase_2.
//! Currently 300 ms + 2 s = 2.3 s. The daemon does not start processing
//! button events until all three phases complete.

use std::collections::BTreeSet;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Context;
use thiserror::Error;
use tokio::sync::{broadcast, mpsc};

use crate::config::Config;
use crate::controller::Controller;
use crate::domain::event::Event;
use crate::mqtt::{MqttBridge, MqttConfig, MqttError};
use crate::time::Clock;
use crate::topology::{Topology, TopologyError};
use crate::web::decision_capture;
use crate::web::server::{WebHandle, WsCommand};
use crate::web::snapshot;

/// Inter-publish gap when bursting `/get` queries to z2m during the
/// startup state refresh. Each /get triggers a zigbee read, so flooding
/// them risks stalling z2m's worker queue.
const GET_BURST_INTERPACKET_DELAY: Duration = Duration::from_millis(50);

#[derive(Debug, Error)]
pub enum DaemonError {
    #[error("topology validation failed: {0}")]
    Topology(#[from] TopologyError),

    #[error("mqtt error: {0}")]
    Mqtt(#[from] MqttError),
}

/// Build and run the daemon. Blocks until shutdown.
///
/// If `web` is `Some`, the event loop serves WebSocket commands and
/// broadcasts state updates / decision logs to connected clients.
pub async fn run(
    config: Config,
    mqtt: MqttConfig,
    clock: Arc<dyn Clock>,
    web: Option<WebHandle>,
) -> anyhow::Result<()> {
    let topology = Arc::new(Topology::build(&config).context("topology validation")?);
    let defaults = config.defaults.clone();

    tracing::info!(
        rooms = topology.rooms().count(),
        switches = topology.all_switch_names().len(),
        taps = topology.all_tap_names().len(),
        motion_sensors = topology.all_motion_sensor_names().len(),
        groups = topology.all_group_names().len(),
        plugs = topology.all_plug_names().len(),
        actions = topology.actions().len(),
        "topology built"
    );

    let mut controller = Controller::new(topology.clone(), clock.clone(), defaults);

    tracing::info!(
        host = %mqtt.host,
        port = mqtt.port,
        "connecting to mqtt"
    );
    let (bridge, mut event_rx) = MqttBridge::start(mqtt, topology.clone(), clock.clone())
        .await
        .context("connecting to mqtt broker")?;

    refresh_state(&mut controller, &bridge, &mut event_rx, &topology).await?;

    // Default any room that the refresh found "physically on" to
    // motion-owned. We can't tell from MQTT alone whether it was a
    // user press or a motion event that turned the lights on; the
    // motion-default loses one false auto-off in the worst case but
    // gains the ability to auto-clear lights left on at boot.
    controller.log_startup_lit_rooms();
    controller.arm_kill_switches_for_active_plugs(clock.now());

    tracing::info!("startup state refresh complete; entering event loop");

    run_event_loop(&mut controller, &bridge, &mut event_rx, web, clock).await
}

/// Three-phase startup state refresh. See module docs.
async fn refresh_state(
    controller: &mut Controller,
    bridge: &MqttBridge,
    event_rx: &mut mpsc::Receiver<Event>,
    topology: &Topology,
) -> Result<(), DaemonError> {
    let all_groups: BTreeSet<String> = topology
        .all_group_names()
        .into_iter()
        .map(String::from)
        .collect();
    let mut seen_groups: BTreeSet<String> = BTreeSet::new();

    // Phase 1: drain retained messages.
    let phase1_window = Duration::from_millis(300);
    let phase1_deadline = Instant::now() + phase1_window;
    drain_until(
        controller,
        bridge,
        event_rx,
        &mut seen_groups,
        phase1_deadline,
        all_groups.len(),
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
        let phase3_deadline = Instant::now() + phase3_window;
        drain_until(
            controller,
            bridge,
            event_rx,
            &mut seen_groups,
            phase3_deadline,
            all_groups.len(),
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
        let zigbee_plug_deadline = Instant::now() + zigbee_plug_drain;
        // Use usize::MAX so drain runs until deadline — we're waiting
        // for plug events, not groups, so the group-count early exit
        // must not apply.
        drain_until(
            controller,
            bridge,
            event_rx,
            &mut seen_groups,
            zigbee_plug_deadline,
            usize::MAX,
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
        let zwave_deadline = Instant::now() + zwave_drain_window;
        drain_until(
            controller,
            bridge,
            event_rx,
            &mut seen_groups,
            zwave_deadline,
            usize::MAX,
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
    controller: &mut Controller,
    bridge: &MqttBridge,
    event_rx: &mut mpsc::Receiver<Event>,
    seen_groups: &mut BTreeSet<String>,
    deadline: Instant,
    expected_total: usize,
) {
    while seen_groups.len() < expected_total {
        let now = Instant::now();
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
                let actions = controller.handle_event(event);
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

/// Tick interval for evaluating kill-switch deadlines.
const TICK_INTERVAL: Duration = Duration::from_secs(5);

/// Main event loop. Reads events forever, dispatches them to the
/// controller, publishes any returned actions. Injects periodic
/// `Tick` events for kill-switch holdoff evaluation. Returns when the
/// channel closes (shutdown signal handling lives one level up).
///
/// When `web` is `Some`, also handles WebSocket commands and broadcasts
/// event/decision log entries and state updates.
async fn run_event_loop(
    controller: &mut Controller,
    bridge: &MqttBridge,
    event_rx: &mut mpsc::Receiver<Event>,
    web: Option<WebHandle>,
    clock: Arc<dyn Clock>,
) -> anyhow::Result<()> {
    let mut tick = tokio::time::interval(TICK_INTERVAL);
    // The first tick fires immediately; skip it so we don't waste a
    // handle_event call right after startup.
    tick.tick().await;

    let (mut ws_cmd_rx, broadcast_tx) = match web {
        Some(wh) => (Some(wh.ws_cmd_rx), Some(wh.broadcast_tx)),
        None => (None, None),
    };
    let has_web = broadcast_tx.is_some();
    let mut event_seq: u64 = 0;

    loop {
        // The select! macro requires all branches to be present at
        // compile time. We use a helper future that never completes
        // when web is disabled, so the branch is dead but compiles.
        let event = tokio::select! {
            msg = event_rx.recv() => {
                match msg {
                    Some(event) => event,
                    None => break,
                }
            }
            _ = tick.tick() => {
                Event::Tick { ts: clock.now() }
            }
            cmd = recv_ws_cmd(&mut ws_cmd_rx) => {
                match cmd {
                    Some(cmd) => {
                        handle_ws_command(
                            cmd,
                            controller,
                            bridge,
                            &broadcast_tx,
                            &*clock,
                        ).await;
                        continue;
                    }
                    None => continue,
                }
            }
        };

        let now = clock.now();

        // Capture tracing decisions if web is enabled.
        if has_web {
            decision_capture::start_capture();
        }

        let event_summary = if has_web {
            snapshot::summarize_event(&event)
        } else {
            String::new()
        };

        let actions = controller.handle_event(event);

        // Broadcast to WebSocket clients.
        if let Some(tx) = &broadcast_tx {
            let decisions = decision_capture::drain_capture();
            if !event_summary.is_empty() || !actions.is_empty() || !decisions.is_empty() {
                event_seq += 1;
                let entry = hue_wire::DecisionLogEntry {
                    seq: event_seq,
                    timestamp_epoch_ms: snapshot::epoch_millis_now(),
                    event_summary,
                    decisions,
                    actions_emitted: actions.iter().map(snapshot::action_to_dto).collect(),
                };
                let _ = tx.send(hue_wire::ServerMessage::EventLog(entry));
            }

            // Broadcast incremental state updates for any room/plug that
            // may have changed. We broadcast all rooms — cheap since we
            // typically have <20 rooms and JSON is small.
            broadcast_state_updates(controller, tx, now);
        }

        // Publish actions to MQTT (the actual side effect).
        for action in actions {
            if let Err(e) = bridge.publish_action(&action).await {
                tracing::error!(error = ?e, "failed to publish action");
            }
        }
    }
    tracing::info!("event channel closed; daemon shutting down");
    Ok(())
}

/// Receive a command from the WebSocket channel if present. Returns
/// `future::pending()` if there is no web handle, so the `select!`
/// branch is effectively disabled.
async fn recv_ws_cmd(
    rx: &mut Option<mpsc::Receiver<WsCommand>>,
) -> Option<WsCommand> {
    match rx {
        Some(rx) => rx.recv().await,
        None => std::future::pending().await,
    }
}

/// Handle a single WebSocket command. Runs synchronously on the event
/// loop thread (no concurrent access to the controller).
async fn handle_ws_command(
    cmd: WsCommand,
    controller: &mut Controller,
    bridge: &MqttBridge,
    broadcast_tx: &Option<broadcast::Sender<hue_wire::ServerMessage>>,
    clock: &dyn Clock,
) {
    match cmd {
        WsCommand::RequestSnapshot { reply } => {
            let snap = snapshot::build_full_snapshot(controller, clock.now());
            let _ = reply.send(snap);
        }
        WsCommand::RequestTopology { reply } => {
            let topo = snapshot::build_topology_info(controller.topology());
            let _ = reply.send(topo);
        }
        WsCommand::RecallScene { room, scene_id } => {
            let actions = controller.web_recall_scene(&room, scene_id, clock.now());
            for action in actions {
                if let Err(e) = bridge.publish_action(&action).await {
                    tracing::error!(error = ?e, "web: failed to publish scene recall");
                }
            }
        }
        WsCommand::SetRoomOff { room } => {
            let actions = controller.web_set_room_off(&room, clock.now());
            for action in actions {
                if let Err(e) = bridge.publish_action(&action).await {
                    tracing::error!(error = ?e, "web: failed to publish room off");
                }
            }
        }
        WsCommand::TogglePlug { device } => {
            let actions = controller.web_toggle_plug(&device, clock.now());
            for action in actions {
                if let Err(e) = bridge.publish_action(&action).await {
                    tracing::error!(error = ?e, "web: failed to publish plug toggle");
                }
            }
        }
    }

    // Broadcast a fresh snapshot after any command so clients see
    // the effect immediately (before the z2m state callback arrives).
    if let Some(tx) = &broadcast_tx {
        broadcast_state_updates(controller, tx, clock.now());
    }
}

/// Broadcast current state of all rooms and plugs to WebSocket clients.
fn broadcast_state_updates(
    controller: &Controller,
    tx: &broadcast::Sender<hue_wire::ServerMessage>,
    now: Instant,
) {
    let topology = controller.topology();
    for room in topology.rooms() {
        if let Some(snap) = snapshot::build_room_snapshot(controller, &room.name, now) {
            let _ = tx.send(hue_wire::ServerMessage::RoomUpdate(snap));
        }
    }
    for plug_name in topology.all_plug_names() {
        if let Some(snap) = snapshot::build_plug_snapshot(controller, plug_name, now) {
            let _ = tx.send(hue_wire::ServerMessage::PlugUpdate(snap));
        }
    }
}
