//! Scheduled `At` trigger evaluation. Called on every tick.

use std::time::Instant;

use crate::domain::action::Action;

use super::Controller;

impl Controller {
    /// Evaluate scheduled `At` triggers. Called on every tick.
    pub(super) fn evaluate_at_triggers(&mut self, ts: Instant) -> Vec<Action> {
        let sun = self.sun_times();
        let current_hour = self.clock.local_hour();
        let current_minute = self.clock.local_minute();
        let bindings_snapshot = self.topology.bindings().to_vec();
        let mut out = Vec::new();
        for resolved in &bindings_snapshot {
            let time_expr = match &resolved.trigger {
                crate::config::Trigger::At { time } => time,
                _ => continue,
            };
            let resolved_minutes = time_expr.resolve(sun.as_ref());
            let target_hour = (resolved_minutes / 60) as u8;
            let target_minute = (resolved_minutes % 60) as u8;
            if current_hour == target_hour && current_minute == target_minute {
                let last = self.at_last_fired.get(&resolved.name);
                if last == Some(&(target_hour, target_minute)) {
                    continue; // already fired this minute
                }
                tracing::info!(
                    rule = resolved.name.as_str(),
                    time = %time_expr,
                    resolved_hour = target_hour,
                    resolved_minute = target_minute,
                    "scheduled trigger fired"
                );
                self.at_last_fired
                    .insert(resolved.name.clone(), (target_hour, target_minute));
                out.extend(self.execute_effect(&resolved.name, &resolved.effect, ts));
            } else {
                // Current time no longer matches — clear the dedup guard
                // so the rule fires again next time the target minute arrives.
                self.at_last_fired.remove(&resolved.name);
            }
        }
        out
    }
}
