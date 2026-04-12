//! A [`tracing_subscriber::Layer`] that captures formatted log messages
//! into a thread-local buffer. The daemon event loop calls
//! [`start_capture`] before `controller.handle_event()` and
//! [`drain_capture`] after, collecting the decision trail for broadcast
//! to WebSocket clients.
//!
//! This works because the event loop runs on a single tokio task (the
//! `select!` loop in `daemon::run_event_loop`), so thread-local storage
//! is stable for the duration of one `handle_event` call.

use std::cell::RefCell;
use std::fmt;

use tracing::field::{Field, Visit};
use tracing::Subscriber;
use tracing_subscriber::layer::Context;
use tracing_subscriber::Layer;

thread_local! {
    static BUFFER: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
    static CAPTURING: RefCell<bool> = const { RefCell::new(false) };
}

/// Clear the buffer and start capturing. Call this right before
/// `controller.handle_event()`.
pub fn start_capture() {
    BUFFER.with(|buf| buf.borrow_mut().clear());
    CAPTURING.with(|c| *c.borrow_mut() = true);
}

/// Stop capturing and drain all collected messages. Call this right
/// after `controller.handle_event()` returns.
pub fn drain_capture() -> Vec<String> {
    CAPTURING.with(|c| *c.borrow_mut() = false);
    BUFFER.with(|buf| buf.borrow_mut().drain(..).collect())
}

/// A tracing layer that, when capture mode is active, records formatted
/// info-level events from `mqtt_controller::*` into the thread-local
/// buffer.
pub struct DecisionCaptureLayer;

impl<S: Subscriber> Layer<S> for DecisionCaptureLayer {
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        let is_capturing = CAPTURING.with(|c| *c.borrow());
        if !is_capturing {
            return;
        }

        let meta = event.metadata();
        if *meta.level() > tracing::Level::INFO {
            return;
        }
        let target = meta.target();
        if !target.starts_with("mqtt_controller") {
            return;
        }

        let mut visitor = MessageVisitor::default();
        event.record(&mut visitor);
        let formatted = visitor.into_formatted();
        BUFFER.with(|buf| buf.borrow_mut().push(formatted));
    }
}

/// Extracts the `message` field from a tracing event plus any
/// additional key=value fields.
#[derive(Default)]
struct MessageVisitor {
    message: String,
    fields: Vec<(String, String)>,
}

impl MessageVisitor {
    /// Consume the visitor and produce a single formatted string with
    /// the message and any structured fields appended.
    fn into_formatted(self) -> String {
        if self.fields.is_empty() {
            return self.message;
        }
        let pairs: Vec<String> = self
            .fields
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect();
        if self.message.is_empty() {
            pairs.join(", ")
        } else {
            format!("{} ({})", self.message, pairs.join(", "))
        }
    }
}

impl Visit for MessageVisitor {
    fn record_debug(&mut self, field: &Field, value: &dyn fmt::Debug) {
        if field.name() == "message" {
            self.message = format!("{value:?}");
        } else {
            self.fields.push((field.name().to_string(), format!("{value:?}")));
        }
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() == "message" {
            self.message = value.to_string();
        } else {
            self.fields.push((field.name().to_string(), value.to_string()));
        }
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        self.fields.push((field.name().to_string(), value.to_string()));
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        self.fields.push((field.name().to_string(), value.to_string()));
    }

    fn record_bool(&mut self, field: &Field, value: bool) {
        self.fields.push((field.name().to_string(), value.to_string()));
    }

    fn record_f64(&mut self, field: &Field, value: f64) {
        self.fields.push((field.name().to_string(), value.to_string()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;

    #[test]
    fn captures_info_events_when_active() {
        // Install subscriber with our layer (only for this test thread).
        let _guard = tracing_subscriber::registry()
            .with(DecisionCaptureLayer)
            .set_default();

        // Not capturing yet — events are discarded.
        tracing::info!(target: "mqtt_controller::controller", "should be ignored");
        let before = drain_capture();
        assert!(before.is_empty());

        // Start capturing.
        start_capture();
        tracing::info!(target: "mqtt_controller::controller", room = "kitchen", "motion on");
        tracing::info!(target: "mqtt_controller::controller", "scene recall");
        tracing::debug!(target: "mqtt_controller::controller", "debug is filtered");
        tracing::info!(target: "other_crate", "wrong target");
        let captured = drain_capture();

        assert_eq!(captured.len(), 2);
        assert!(captured[0].contains("motion on"));
        assert!(captured[0].contains("room=kitchen"));
        assert!(captured[1].contains("scene recall"));
    }

    #[test]
    fn drain_stops_capturing() {
        let _guard = tracing_subscriber::registry()
            .with(DecisionCaptureLayer)
            .set_default();

        start_capture();
        tracing::info!(target: "mqtt_controller::controller", "first");
        let _ = drain_capture();

        // After drain, capturing is off.
        tracing::info!(target: "mqtt_controller::controller", "second");
        let captured = drain_capture();
        assert!(captured.is_empty());
    }
}
