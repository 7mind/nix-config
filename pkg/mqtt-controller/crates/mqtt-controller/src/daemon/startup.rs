//! Startup state seed: prime the world state from z2m (WebSocket API)
//! and `zwave-js-server` (WebSocket API on port 3000) before the event
//! loop takes over.
//!
//! Both seeds talk directly to each bridge's own native WebSocket API
//! — no MQTT. One RTT per bridge covers every entity in one shot,
//! including sleeping or offline ones (each bridge returns its cached
//! state).
//!
//! Seed failure is non-fatal: the daemon logs and continues. The
//! wildcard `zigbee2mqtt/#` + `zwave/#` MQTT subscriptions are already
//! active at this point, so any live publishes that arrive during or
//! after startup flow into the event loop and fill in state.

use std::time::Duration;

use crate::logic::EventProcessor;
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

/// `zwave-js-server` handshake is 4 round-trips; 5 s is ample locally.
const ZWAVE_SEED_TIMEOUT: Duration = Duration::from_secs(5);

/// Prime the world state for every zigbee + z-wave entity the topology
/// knows about. Each bridge is queried independently; a failure on one
/// does not abort the other.
pub(super) async fn refresh_state(
    processor: &mut EventProcessor,
    topology: &Topology,
    clock: &dyn Clock,
    z2m_ws_url: Option<&str>,
    zwave_ws_url: Option<&str>,
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

    // --- z-wave: bulk state via zwave-js-server WebSocket ---
    if !topology.zwave_node_id_to_name().is_empty() {
        match zwave_ws_url {
            Some(url) => match zwave_seed::seed_zwave_state(
                processor,
                url,
                topology,
                clock,
                ZWAVE_SEED_TIMEOUT,
            )
            .await
            {
                Ok(seeded) => {
                    tracing::info!(
                        seeded,
                        "zwave seed: plug states primed from zwave-js-server"
                    );
                }
                Err(e) => {
                    tracing::warn!(
                        error = %e,
                        "zwave seed failed; continuing without z-wave state (live publishes will populate)"
                    );
                }
            },
            None => {
                tracing::info!("zwave seed skipped (no zwave-js-server URL configured)");
            }
        }
    }

    Ok(())
}
