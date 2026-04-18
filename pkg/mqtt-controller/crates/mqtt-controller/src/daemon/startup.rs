//! Startup state seed: prime the world state from z2m (WebSocket API)
//! and Z-Wave JS UI (MQTT `getNodes` API) before the event loop takes
//! over.
//!
//! Both seeds talk directly to each bridge's own API instead of relying
//! on retained MQTT or per-device `/get` cascades. One RTT per bridge
//! covers every device in one shot, including sleeping or offline ones
//! (the bridge returns its cached state).
//!
//! Seed failure is non-fatal: the daemon logs and continues. The
//! wildcard `zigbee2mqtt/#` + `zwave/#` subscriptions are already
//! active at this point, so any live publishes that arrive during or
//! after startup flow into the event loop and fill in state.

use std::time::Duration;

use crate::logic::EventProcessor;
use crate::mqtt::MqttConfig;
use crate::time::Clock;
use crate::topology::Topology;

use super::z2m_seed;
use super::zwave_seed;
use super::DaemonError;

/// Timeout for a single z2m WebSocket attempt. Scaled generously since
/// this happens exactly once per daemon startup and z2m can be slow
/// right after boot.
const Z2M_SEED_TIMEOUT: Duration = Duration::from_secs(15);

/// Total wall time budget for the z2m seed (retries × timeout).
const Z2M_SEED_RETRY_DELAY: Duration = Duration::from_secs(5);
const Z2M_SEED_ATTEMPTS: u32 = 6;

/// Z-Wave JS UI `getNodes` call is a single MQTT request/response.
const ZWAVE_SEED_TIMEOUT: Duration = Duration::from_secs(5);

/// Prime the world state for every zigbee + z-wave entity the topology
/// knows about. Each bridge is queried independently; a failure on one
/// does not abort the other.
pub(super) async fn refresh_state(
    processor: &mut EventProcessor,
    topology: &Topology,
    clock: &dyn Clock,
    mqtt_config: &MqttConfig,
    z2m_ws_url: Option<&str>,
) -> Result<(), DaemonError> {
    // --- z2m: bulk state via WebSocket /api (skipped if no URL) ---
    if let Some(ws_url) = z2m_ws_url {
        match z2m_seed::seed_z2m_state(
            processor,
            topology,
            ws_url,
            clock,
            Z2M_SEED_TIMEOUT,
            Z2M_SEED_ATTEMPTS,
            Z2M_SEED_RETRY_DELAY,
        )
        .await
        {
            Ok(s) => {
                tracing::info!(
                    groups = s.groups,
                    lights = s.lights,
                    plugs = s.plugs,
                    trvs = s.trvs,
                    wall_thermostats = s.wall_thermostats,
                    motion_sensors = s.motion_sensors,
                    ignored = s.ignored,
                    "z2m seed: state primed from WebSocket /api"
                );
            }
            Err(e) => {
                tracing::warn!(
                    error = %e,
                    "z2m seed failed; continuing with empty state (live publishes will populate)"
                );
            }
        }
    } else {
        tracing::info!("z2m seed skipped (no WebSocket URL configured)");
    }

    // --- z-wave: bulk state via MQTT getNodes API ---
    if !topology.zwave_node_id_to_name().is_empty() {
        match zwave_seed::seed_zwave_state(
            processor,
            mqtt_config,
            topology,
            clock,
            ZWAVE_SEED_TIMEOUT,
        )
        .await
        {
            Ok(seeded) => {
                tracing::info!(seeded, "zwave seed: plug states primed from getNodes");
            }
            Err(e) => {
                tracing::warn!(
                    error = %e,
                    "zwave seed failed; continuing without z-wave state (live publishes will populate)"
                );
            }
        }
    }

    Ok(())
}
