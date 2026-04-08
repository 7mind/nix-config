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
use tokio::sync::mpsc;

use crate::config::{Config, Defaults};
use crate::controller::Controller;
use crate::domain::event::Event;
use crate::mqtt::{MqttBridge, MqttConfig, MqttError};
use crate::time::Clock;
use crate::topology::{Topology, TopologyError};

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
pub async fn run(
    config: Config,
    mqtt: MqttConfig,
    clock: Arc<dyn Clock>,
) -> anyhow::Result<()> {
    let topology = Arc::new(Topology::build(&config).context("topology validation")?);
    let defaults = config.defaults.clone();

    tracing::info!(
        rooms = topology.rooms().count(),
        switches = topology.all_switch_names().len(),
        taps = topology.all_tap_names().len(),
        motion_sensors = topology.all_motion_sensor_names().len(),
        groups = topology.all_group_names().len(),
        "topology built"
    );

    let mut controller = Controller::new(topology.clone(), clock, defaults);

    tracing::info!(
        host = %mqtt.host,
        port = mqtt.port,
        "connecting to mqtt"
    );
    let (bridge, mut event_rx) = MqttBridge::start(mqtt, topology.clone())
        .await
        .context("connecting to mqtt broker")?;

    refresh_state(&mut controller, &bridge, &mut event_rx, &topology).await?;

    // Default any room that the refresh found "physically on" to
    // motion-owned. We can't tell from MQTT alone whether it was a
    // user press or a motion event that turned the lights on; the
    // motion-default loses one false auto-off in the worst case but
    // gains the ability to auto-clear lights left on at boot.
    controller.seed_motion_ownership_for_lit_rooms();

    tracing::info!("startup state refresh complete; entering event loop");

    run_event_loop(&mut controller, &bridge, &mut event_rx).await
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

    // Phase 2: /get the missing groups.
    let missing: Vec<String> = all_groups.difference(&seen_groups).cloned().collect();
    if missing.is_empty() {
        return Ok(());
    }
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

/// Main event loop. Reads events forever, dispatches them to the
/// controller, publishes any returned actions. Returns when the channel
/// closes (shutdown signal handling lives one level up).
async fn run_event_loop(
    controller: &mut Controller,
    bridge: &MqttBridge,
    event_rx: &mut mpsc::Receiver<Event>,
) -> anyhow::Result<()> {
    while let Some(event) = event_rx.recv().await {
        let actions = controller.handle_event(event);
        for action in actions {
            if let Err(e) = bridge.publish_action(&action).await {
                tracing::error!(error = ?e, "failed to publish action");
            }
        }
    }
    tracing::info!("event channel closed; daemon shutting down");
    Ok(())
}

// `Defaults` is re-imported here so the doc comment at the top of this
// module can mention it without a disambiguating path. The actual
// daemon::run signature uses Config which carries Defaults inside.
#[allow(dead_code)]
const _DEFAULTS_REFERENCE: std::marker::PhantomData<Defaults> = std::marker::PhantomData;
