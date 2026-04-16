//! The runtime daemon: wires the [`MqttBridge`] to the [`EventProcessor`],
//! performs the startup state refresh, then runs the event loop until
//! shutdown.
//!
//! Submodules:
//!
//!   * [`startup`]    — three-phase MQTT state refresh that primes the
//!     world state before normal event processing begins.
//!   * [`event_loop`] — the long-running select loop.
//!   * [`web_bridge`] — WebSocket command + broadcast helpers used by
//!     the event loop when started with a [`WebHandle`].
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

use std::sync::Arc;

use anyhow::Context;
use thiserror::Error;

use crate::config::Config;
use crate::effect_dispatch;
use crate::logic::EventProcessor;
use crate::mqtt::{MqttBridge, MqttConfig, MqttError};
use crate::time::Clock;
use crate::topology::{Topology, TopologyError};
use crate::web::server::WebHandle;

mod event_loop;
mod startup;
mod web_bridge;

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
        switches = topology.all_switch_device_names().len(),
        motion_sensors = topology.all_motion_sensor_names().len(),
        groups = topology.all_group_names().len(),
        plugs = topology.all_plug_names().len(),
        trvs = topology.all_trv_names().len(),
        wall_thermostats = topology.all_wall_thermostat_names().len(),
        bindings = topology.bindings().len(),
        heating = topology.heating_config().is_some(),
        "topology built"
    );

    let mut processor = EventProcessor::new(topology.clone(), clock.clone(), defaults, config.location);

    tracing::info!(
        host = %mqtt.host,
        port = mqtt.port,
        "connecting to mqtt"
    );
    let (bridge, mut event_rx) = MqttBridge::start(mqtt, topology.clone(), clock.clone())
        .await
        .context("connecting to mqtt broker")?;

    startup::refresh_state(&mut processor, &bridge, &mut event_rx, &topology, &*clock).await?;

    // Turn off any motion-controlled room that was left on before
    // restart. No cooldown is applied so motion sensors can
    // immediately re-trigger if someone is actually in the room.
    let startup_effects = processor.startup_turn_off_motion_zones(clock.now());
    effect_dispatch::dispatch(&bridge, &topology, &startup_effects).await;
    processor.arm_kill_switches_for_active_plugs(clock.now());

    tracing::info!("startup state refresh complete; entering event loop");

    event_loop::run_event_loop(&mut processor, &bridge, &mut event_rx, web, clock).await
}
