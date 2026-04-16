//! Plug state tracking and kill-switch evaluation.
//!
//! Operates on [`PlugEntity`] TASS entities with per-rule
//! [`KillSwitchRuleState`] enum.

use std::time::{Duration, Instant};

use crate::domain::action::{Action, Payload};
use crate::entities::plug::{KillSwitchRuleState, PlugActual, PlugTarget};
use crate::tass::{ActualFreshness, Owner, TargetPhase};
use crate::topology::ResolvedTrigger;

use super::EventProcessor;

impl EventProcessor {
    /// Handle a plug state or power update.
    ///
    /// When `on` is `Some`, the plug's on/off state is updated.
    /// When `None` (Z-Wave meter-only updates), only the power reading
    /// is merged into the existing actual state.
    pub(super) fn handle_plug_state(
        &mut self,
        device: &str,
        on: Option<bool>,
        power: Option<f64>,
        ts: Instant,
    ) -> Vec<Action> {
        let clamped_power = power.map(|w| w.max(0.0));

        let plug = self.world.plug(device);
        let was_on = plug.is_on();
        let was_known = plug.actual.freshness() != ActualFreshness::Unknown;

        match on {
            Some(on_val) => {
                // Full state update: update actual with on/off + power.
                plug.actual.update(PlugActual { on: on_val, power: clamped_power }, ts);
            }
            None => {
                // Power-only update (Z-Wave meter). Merge power into existing
                // actual without touching the on/off state.
                if let Some(actual) = plug.actual.value_mut() {
                    actual.power = clamped_power;
                } else {
                    // Never seen this plug — store the power but leave
                    // freshness as Unknown (no on/off state known yet).
                    // We cannot call actual.update() because that would
                    // set freshness to Fresh with an unknown on/off.
                    // Instead, just return — we'll pick it up on the
                    // next full state update.
                    return Vec::new();
                }
            }
        }

        let is_on = plug.is_on();

        // Off transition: clear kill switches, confirm target if it
        // was already Off. Do NOT override the target owner — the echo
        // is an observation, not a command.
        if on == Some(false) {
            plug.on_off_clear_kill_switches();
            self.maybe_confirm_plug_target(device, ts);
            return Vec::new();
        }

        if !is_on {
            return Vec::new();
        }

        // Off-to-on transition: arm kill switch rules.
        if on == Some(true) && (!was_on || !was_known) {
            self.arm_kill_switch_rules(device, clamped_power, ts, ArmCause::OffOnTransition);
        }

        // Confirm target if actual matches.
        self.maybe_confirm_plug_target(device, ts);

        // Evaluate kill switch rules with effective power.
        let effective_power = {
            let plug = self.world.plugs.get(device);
            clamped_power.or_else(|| plug.and_then(|p| p.power()))
        };

        let Some(effective_power) = effective_power else {
            return Vec::new();
        };

        self.evaluate_kill_switch(device, effective_power, ts)
    }

    /// Evaluate kill switch rules for a plug against a power reading.
    /// Ports `KillSwitchEvaluator::evaluate()`.
    fn evaluate_kill_switch(
        &mut self,
        device: &str,
        power: f64,
        ts: Instant,
    ) -> Vec<Action> {
        let topology = self.topology.clone();
        let Some(device_idx) = topology.device_idx(device) else {
            return Vec::new();
        };
        let rule_indexes = topology.bindings_for_power_below(device_idx);
        if rule_indexes.is_empty() {
            return Vec::new();
        }

        // Pre-extract rule info from topology to avoid borrow conflicts.
        struct RuleInfo {
            rule_name: String,
            threshold_watts: f64,
            holdoff: Duration,
            target: Option<String>,
        }
        let rules: Vec<RuleInfo> = rule_indexes
            .iter()
            .filter_map(|&idx| {
                let resolved = topology.binding(idx);
                match &resolved.trigger {
                    ResolvedTrigger::PowerBelow {
                        watts, holdoff, ..
                    } => Some(RuleInfo {
                        rule_name: resolved.name.clone(),
                        threshold_watts: *watts,
                        holdoff: *holdoff,
                        target: resolved
                            .effect
                            .target_plug()
                            .map(|p| topology.device_name(p.device()).to_string()),
                    }),
                    _ => None,
                }
            })
            .collect();

        let plug = self.world.plug(device);
        let mut fired_targets: Vec<(String, String)> = Vec::new();

        for rule in &rules {
            let state = plug
                .kill_switch_rules
                .entry(rule.rule_name.clone())
                .or_insert(KillSwitchRuleState::Inactive);

            if power < rule.threshold_watts {
                match state {
                    KillSwitchRuleState::Inactive => {
                        tracing::info!(
                            device,
                            rule = %rule.rule_name,
                            power,
                            threshold = rule.threshold_watts,
                            "kill switch: below threshold but not yet armed \
                             (waiting for first above-threshold reading)"
                        );
                    }
                    KillSwitchRuleState::Suppressed => {
                        // Stay suppressed until power recovers.
                    }
                    KillSwitchRuleState::Armed => {
                        tracing::info!(
                            device,
                            rule = %rule.rule_name,
                            power,
                            threshold = rule.threshold_watts,
                            "kill switch: power dropped below threshold, starting holdoff"
                        );
                        *state = KillSwitchRuleState::Idle { since: ts };
                    }
                    KillSwitchRuleState::Idle { since } => {
                        if ts.duration_since(*since) >= rule.holdoff {
                            tracing::info!(
                                device,
                                rule = %rule.rule_name,
                                holdoff_secs = rule.holdoff.as_secs(),
                                "kill switch: holdoff elapsed, turning off plug"
                            );
                            if let Some(target) = &rule.target {
                                fired_targets
                                    .push((rule.rule_name.clone(), target.clone()));
                            }
                            break;
                        }
                    }
                }
            } else {
                // Power above threshold: arm, clear idle, lift suppression.
                match state {
                    KillSwitchRuleState::Suppressed => {
                        tracing::info!(
                            device,
                            rule = %rule.rule_name,
                            power,
                            threshold = rule.threshold_watts,
                            "kill switch: power recovered above threshold, resetting holdoff"
                        );
                        *state = KillSwitchRuleState::Armed;
                    }
                    KillSwitchRuleState::Idle { .. } => {
                        tracing::info!(
                            device,
                            rule = %rule.rule_name,
                            power,
                            threshold = rule.threshold_watts,
                            "kill switch: power recovered above threshold, resetting holdoff"
                        );
                        *state = KillSwitchRuleState::Armed;
                    }
                    KillSwitchRuleState::Inactive => {
                        *state = KillSwitchRuleState::Armed;
                    }
                    KillSwitchRuleState::Armed => {}
                }
            }
        }

        self.apply_kill_switch_fired(device, &fired_targets, ts)
    }

    /// Tick-based kill switch evaluation. Checks all plugs that are on
    /// for idle rules whose holdoff has elapsed.
    /// Ports `KillSwitchEvaluator::tick()`.
    pub(super) fn evaluate_kill_switch_ticks(&mut self, ts: Instant) -> Vec<Action> {
        let topology = self.topology.clone();
        let bindings_snapshot = topology.bindings().to_vec();

        // Collect all (device, rule_name, holdoff, target) for PowerBelow rules
        // whose plug is on and has an idle timer running.
        let mut to_fire: Vec<(String, String, String)> = Vec::new();

        for resolved in &bindings_snapshot {
            let (plug, holdoff) = match &resolved.trigger {
                ResolvedTrigger::PowerBelow { plug, holdoff, .. } => (*plug, *holdoff),
                _ => continue,
            };

            let device = topology.device_name(plug.device());
            let Some(plug_entity) = self.world.plugs.get(device) else {
                continue;
            };
            if !plug_entity.is_on() {
                continue;
            }

            let Some(state) = plug_entity.kill_switch_rules.get(&resolved.name) else {
                continue;
            };
            let KillSwitchRuleState::Idle { since } = state else {
                continue;
            };

            if ts.duration_since(*since) >= holdoff {
                tracing::info!(
                    device,
                    rule = %resolved.name,
                    holdoff_secs = holdoff.as_secs(),
                    "tick: kill switch holdoff elapsed, turning off plug"
                );
                if let Some(target_plug) = resolved.effect.target_plug() {
                    let target = topology.device_name(target_plug.device()).to_string();
                    to_fire.push((
                        device.to_string(),
                        resolved.name.clone(),
                        target,
                    ));
                }
            }
        }

        let mut out = Vec::new();
        for (device, rule_name, target) in to_fire {
            out.extend(self.apply_kill_switch_fired(
                &device,
                &[(rule_name, target)],
                ts,
            ));
        }
        out
    }

    /// Earliest kill-switch idle start across all `PowerBelow` rules
    /// targeting `device`. For web UI snapshot.
    pub fn earliest_kill_switch_idle(&self, device: &str) -> Option<Instant> {
        let plug = self.world.plugs.get(device)?;
        let topology = &self.topology;
        let device_idx = topology.device_idx(device)?;
        topology
            .bindings_for_power_below(device_idx)
            .iter()
            .filter_map(|&idx| {
                let name = &topology.binding(idx).name;
                match plug.kill_switch_rules.get(name) {
                    Some(KillSwitchRuleState::Idle { since }) => Some(*since),
                    _ => None,
                }
            })
            .min()
    }

    /// Maximum holdoff duration (seconds) across all `PowerBelow` rules
    /// targeting `device` that are currently idle. For web UI snapshot.
    pub fn kill_switch_holdoff_secs(&self, device: &str) -> Option<u64> {
        let plug = self.world.plugs.get(device)?;
        let topology = &self.topology;
        let device_idx = topology.device_idx(device)?;
        topology
            .bindings_for_power_below(device_idx)
            .iter()
            .filter_map(|&idx| {
                let resolved = topology.binding(idx);
                if !matches!(
                    plug.kill_switch_rules.get(&resolved.name),
                    Some(KillSwitchRuleState::Idle { .. })
                ) {
                    return None;
                }
                match &resolved.trigger {
                    ResolvedTrigger::PowerBelow { holdoff, .. } => Some(holdoff.as_secs()),
                    _ => None,
                }
            })
            .max()
    }

    // ----- private helpers ---------------------------------------------------

    /// Arm kill switch rules for a plug. Used in two contexts:
    /// off→on runtime transitions and the daemon's startup pre-arm
    /// for plugs that are already on. The state-machine logic is
    /// identical; only the log messages differ. See [`ArmCause`].
    pub(super) fn arm_kill_switch_rules(
        &mut self,
        device: &str,
        seed_power: Option<f64>,
        ts: Instant,
        cause: ArmCause,
    ) {
        let topology = self.topology.clone();
        let Some(device_idx) = topology.device_idx(device) else {
            return;
        };
        let plug = self.world.plug(device);

        for &idx in topology.bindings_for_power_below(device_idx) {
            let resolved = topology.binding(idx);
            let rule_name = resolved.name.clone();

            let entry = plug
                .kill_switch_rules
                .entry(rule_name.clone())
                .or_insert(KillSwitchRuleState::Inactive);

            // Skip already-armed or suppressed rules.
            if matches!(entry, KillSwitchRuleState::Suppressed | KillSwitchRuleState::Armed) {
                continue;
            }

            *entry = KillSwitchRuleState::Armed;

            if let Some(current_power) = seed_power {
                if let ResolvedTrigger::PowerBelow { watts, .. } = &resolved.trigger {
                    if current_power < *watts {
                        tracing::info!(
                            device,
                            rule = %rule_name,
                            power = current_power,
                            threshold = watts,
                            "{}", cause.idle_msg(),
                        );
                        *entry = KillSwitchRuleState::Idle { since: ts };
                        continue;
                    }
                }
            }

            tracing::info!(device, rule = %rule_name, "{}", cause.arm_msg());
        }
    }
}

/// Why we are arming kill switches on a plug. Distinguishes log lines
/// between the two callers without duplicating the underlying state
/// machine.
#[derive(Debug, Clone, Copy)]
pub(super) enum ArmCause {
    /// Daemon startup: plug was already on when we connected.
    Startup,
    /// Runtime: plug just transitioned from off to on.
    OffOnTransition,
}

impl ArmCause {
    fn idle_msg(&self) -> &'static str {
        match self {
            Self::Startup => "startup: pre-arming AND seeding idle (power already below threshold)",
            Self::OffOnTransition => "auto-arm: seeding idle (power already below threshold)",
        }
    }
    fn arm_msg(&self) -> &'static str {
        match self {
            Self::Startup => "startup: pre-arming kill switch for active plug",
            Self::OffOnTransition => "auto-arm: arming kill switch on off->on transition",
        }
    }
}

impl crate::logic::EventProcessor {
    /// Apply kill switch fire results: suppress all rules on the device,
    /// update plug state, produce turn-off actions.
    fn apply_kill_switch_fired(
        &mut self,
        device: &str,
        fired: &[(String, String)],
        ts: Instant,
    ) -> Vec<Action> {
        if fired.is_empty() {
            return Vec::new();
        }

        // Suppress all rules on the source device.
        let plug = self.world.plug(device);
        plug.suppress_all_kill_switches();

        let mut out = Vec::new();
        for (_rule_name, target) in fired {
            let target_plug = self.world.plug(target);
            target_plug
                .target
                .set_and_command(PlugTarget::Off, Owner::Rule, ts);
            target_plug.on_off_clear_kill_switches();
            out.push(Action::for_device(target, Payload::device_off()));
        }
        out
    }

    /// Confirm plug target if actual state matches.
    fn maybe_confirm_plug_target(&mut self, device: &str, ts: Instant) {
        let plug = self.world.plug(device);
        let phase = plug.target.phase();
        if !matches!(phase, TargetPhase::Commanded | TargetPhase::Stale) {
            return;
        }
        let target_val = plug.target.value().copied();
        let actual_on = plug.actual.value().map(|a| a.on);
        let matches = match (target_val, actual_on) {
            (Some(PlugTarget::On), Some(true)) => true,
            (Some(PlugTarget::Off), Some(false)) => true,
            _ => false,
        };
        if matches {
            plug.target.confirm(ts);
        }
    }
}
