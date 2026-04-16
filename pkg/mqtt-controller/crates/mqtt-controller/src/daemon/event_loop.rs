//! Main event loop. Reads events forever, dispatches them to the
//! controller, publishes any returned actions. Injects periodic
//! `Tick` events for kill-switch holdoff evaluation. Returns when the
//! channel closes (shutdown signal handling lives one level up).

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::mpsc;

use crate::domain::event::Event;
use crate::logic::EventProcessor;
use crate::mqtt::MqttBridge;
use crate::time::Clock;
use crate::web::decision_capture;
use crate::web::event_log;
use crate::web::server::WebHandle;

use super::web_bridge::{broadcast_state_updates, handle_ws_command, recv_ws_cmd};

/// Tick interval for evaluating kill-switch deadlines.
const TICK_INTERVAL: Duration = Duration::from_secs(5);

/// When `web` is `Some`, also handles WebSocket commands and broadcasts
/// event/decision log entries and state updates.
pub(super) async fn run_event_loop(
    processor: &mut EventProcessor,
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
        //
        // The press deadline branch handles deferred soft-double-tap
        // detection: when a button has soft_double_tap bindings,
        // the first press is buffered for a short window. This branch
        // flushes it as a single press once the window expires.
        let switch_deadline_sleep = async {
            match processor.next_press_deadline() {
                Some(deadline) => {
                    let now = std::time::Instant::now();
                    if deadline <= now {
                        return;
                    }
                    tokio::time::sleep(deadline - now).await;
                }
                None => std::future::pending::<()>().await,
            }
        };
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
            _ = switch_deadline_sleep => {
                Event::Tick { ts: clock.now() }
            }
            cmd = recv_ws_cmd(&mut ws_cmd_rx) => {
                match cmd {
                    Some(cmd) => {
                        handle_ws_command(
                            cmd,
                            processor,
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
            event_log::summarize_event(&event)
        } else {
            String::new()
        };

        // Extract event-side entity names before the event is consumed.
        let event_entities = if has_web {
            event_log::extract_event_entities(&event, processor.topology())
        } else {
            Vec::new()
        };

        let is_user_action = matches!(
            &event,
            Event::ButtonPress { .. }
        );

        let actions = processor.handle_event(event);

        // Broadcast to WebSocket clients.
        if let Some(tx) = &broadcast_tx {
            let decisions = decision_capture::drain_capture();
            // Only log events that are interesting: user button presses,
            // or events where the controller actually did something
            // (emitted actions or captured decision traces). This filters
            // out the bulk of noise: zigbee state echoes, power updates,
            // TRV telemetry, and ticks with no side effects.
            let has_actions = !actions.is_empty();
            let has_decisions = !decisions.is_empty();
            if is_user_action || has_actions || has_decisions {
                // Filter out HA discovery/state Raw actions from the log
                // — they fire every tick and would still be noisy.
                let visible_actions: Vec<_> = actions
                    .iter()
                    .filter(|a| !matches!(
                        a.target,
                        crate::domain::action::ActionTarget::Raw { .. }
                    ))
                    .map(event_log::action_to_dto)
                    .collect();
                let should_log = is_user_action
                    || !visible_actions.is_empty()
                    || has_decisions;
                if should_log {
                    event_seq += 1;
                    let involved_entities = event_log::finish_involved_entities(
                        event_entities,
                        &actions,
                        processor.topology(),
                    );
                    let entry = mqtt_controller_wire::DecisionLogEntry {
                        seq: event_seq,
                        timestamp_epoch_ms: clock.epoch_millis(),
                        event_summary,
                        decisions,
                        actions_emitted: visible_actions,
                        involved_entities,
                    };
                    let _ = tx.send(mqtt_controller_wire::ServerMessage::EventLog(entry));
                }
            }

            // Broadcast incremental state updates for any room/plug that
            // may have changed. We broadcast all rooms — cheap since we
            // typically have <20 rooms and JSON is small.
            broadcast_state_updates(processor, tx, now);
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
