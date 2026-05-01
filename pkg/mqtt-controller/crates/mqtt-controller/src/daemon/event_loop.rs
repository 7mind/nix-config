//! Main event loop. Reads events forever, dispatches them to the
//! controller, publishes any returned actions. Injects periodic
//! `Tick` events for kill-switch holdoff evaluation. Returns when the
//! channel closes (shutdown signal handling lives one level up).

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::mpsc;

use crate::domain::event::Event;
use crate::effect_dispatch;
use crate::logic::EventProcessor;
use crate::mqtt::MqttBridge;
use crate::time::Clock;
use crate::web::decision_capture;
use crate::web::event_log;
use crate::web::server::WebHandle;

use super::web_bridge::{
    broadcast_state_updates, broadcast_touched, handle_ws_command, recv_ws_cmd,
};

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

    let (mut ws_cmd_rx, broadcast_tx, audit_writer) = match web {
        Some(wh) => (Some(wh.ws_cmd_rx), Some(wh.broadcast_tx), wh.audit_writer),
        None => (None, None, None),
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
        // Tick handlers (`evaluate_target_staleness`,
        // `evaluate_actual_staleness`, schedule, kill-switch holdoffs,
        // heating reconciliation) can flip target/freshness fields on
        // arbitrary entities without emitting effects. Rather than
        // teach each tick path to publish its touched-entity set, fall
        // back to a full broadcast on every tick — ticks are slow
        // (5 s interval) so the cost is negligible.
        let is_tick = matches!(&event, Event::Tick { .. });

        // The event itself can mutate world state without producing
        // any effect (group/plug/TRV/WT echoes, motion updates, …);
        // capture the implied touched-entities BEFORE handing the
        // event to the processor so the dashboard sees those updates
        // alongside effect-driven ones.
        let topology = processor.topology().clone();
        let mut touched = effect_dispatch::touched_from_event(&event, &topology);

        let effects = processor.handle_event(event);

        // Dispatch effects to MQTT and merge the effect-side touched
        // set into the broadcast set.
        let dispatch_touched = effect_dispatch::dispatch(bridge, &topology, &effects).await;
        touched.extend(dispatch_touched);

        // Broadcast to WebSocket clients.
        if let Some(tx) = &broadcast_tx {
            let decisions = decision_capture::drain_capture();
            // Only log events that are interesting: user button presses,
            // or events where the controller actually did something
            // (emitted effects or captured decision traces). This filters
            // out the bulk of noise: zigbee state echoes, power updates,
            // TRV telemetry, and ticks with no side effects.
            let has_effects = !effects.is_empty();
            let has_decisions = !decisions.is_empty();
            if is_user_action || has_effects || has_decisions {
                // Filter out HA discovery/state Raw effects from the log
                // — they fire every tick and would still be noisy.
                let visible_effects: Vec<_> = effects
                    .iter()
                    .filter(|e| !matches!(
                        e,
                        crate::domain::Effect::PublishRaw { .. }
                            | crate::domain::Effect::PublishHaDiscoveryZone { .. }
                            | crate::domain::Effect::PublishHaDiscoveryTrv { .. }
                            | crate::domain::Effect::PublishHaStateZone { .. }
                            | crate::domain::Effect::PublishHaStateTrv { .. }
                    ))
                    .map(|e| event_log::effect_to_dto(e, &topology))
                    .collect();
                let should_log = is_user_action
                    || !visible_effects.is_empty()
                    || has_decisions;
                if should_log {
                    event_seq += 1;
                    let involved_entities = event_log::finish_involved_entities(
                        event_entities,
                        &effects,
                        &topology,
                    );
                    let entry = mqtt_controller_wire::DecisionLogEntry {
                        seq: event_seq,
                        timestamp_epoch_ms: clock.epoch_millis(),
                        event_summary,
                        decisions,
                        actions_emitted: visible_effects,
                        involved_entities,
                    };
                    if let Some(audit) = &audit_writer {
                        audit.try_send(entry.clone());
                    }
                    let _ = tx.send(mqtt_controller_wire::ServerMessage::EventLog(entry));
                }
            }

            // Broadcast incremental state updates for entities that
            // were actually touched by this batch of effects. Tick
            // events get a full sweep because tick handlers mutate
            // target/freshness silently (see comment above).
            if is_tick {
                broadcast_state_updates(processor, tx, now);
            } else {
                broadcast_touched(processor, tx, &touched, now);
            }
        }
    }
    tracing::info!("event channel closed; daemon shutting down");
    Ok(())
}
