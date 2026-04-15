//! Kill-switch evaluator. Monitors plug power readings against
//! `PowerBelow` action rules and fires after a configurable holdoff.
//!
//! Owns three pieces of state that were previously inlined in
//! [`super::Controller`]:
//!
//!   * **idle_since** — per-rule timestamp when power first dropped below
//!     threshold. The holdoff clock starts here.
//!   * **armed** — a rule is armed once power has been observed *above*
//!     threshold at least once since the plug turned on. Prevents
//!     immediate re-trip after a manual re-enable while the device is
//!     still warming up.
//!   * **suppressed** — set for ALL rules on a plug when any kill-switch
//!     fires. Cleared per-rule when that rule sees an above-threshold
//!     reading. Guards against re-arm during warmup after an explicit
//!     kill.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::config::Trigger;
use crate::topology::Topology;

/// Returned when a kill-switch holdoff elapses and the plug should be
/// turned off. The caller is responsible for updating plug state and
/// publishing the MQTT action.
#[derive(Debug, Clone)]
pub struct KillSwitchFired {
    pub device: String,
    pub rule_name: String,
    /// The target device from the rule's effect (may differ from
    /// `device` if a rule turns off a different plug).
    pub target: String,
}

#[derive(Debug)]
pub struct KillSwitchEvaluator {
    topology: Arc<Topology>,
    idle_since: BTreeMap<String, Instant>,
    armed: BTreeSet<String>,
    suppressed: BTreeSet<String>,
}

impl KillSwitchEvaluator {
    pub fn new(topology: Arc<Topology>) -> Self {
        Self {
            topology,
            idle_since: BTreeMap::new(),
            armed: BTreeSet::new(),
            suppressed: BTreeSet::new(),
        }
    }

    /// True if a holdoff is currently running for the given rule name.
    pub fn is_idle(&self, rule_name: &str) -> bool {
        self.idle_since.contains_key(rule_name)
    }

    /// Earliest idle start across all `PowerBelow` rules targeting
    /// `device`. Returns `None` if no rule is currently tracking idle.
    pub fn earliest_idle(&self, device: &str) -> Option<Instant> {
        self.topology
            .bindings_for_power_below(device)
            .iter()
            .filter_map(|&idx| {
                let name = &self.topology.bindings()[idx].name;
                self.idle_since.get(name).copied()
            })
            .min()
    }

    /// Maximum holdoff duration across all `PowerBelow` rules targeting
    /// `device` that are currently tracking idle. Returns `None` if no
    /// rule is idle.
    pub fn holdoff_secs(&self, device: &str) -> Option<u64> {
        self.topology
            .bindings_for_power_below(device)
            .iter()
            .filter_map(|&idx| {
                let resolved = &self.topology.bindings()[idx];
                if !self.idle_since.contains_key(&resolved.name) {
                    return None;
                }
                match &resolved.trigger {
                    Trigger::PowerBelow { for_seconds, .. } => Some(*for_seconds),
                    _ => None,
                }
            })
            .max()
    }

    /// Clear all kill-switch tracking for a device. Called on any
    /// off-transition (explicit off, toggle off, kill-switch fire from
    /// the controller side, etc.).
    pub fn on_plug_off(&mut self, device: &str) {
        for &idx in self.topology.bindings_for_power_below(device) {
            let name = &self.topology.bindings()[idx].name;
            self.idle_since.remove(name);
            self.armed.remove(name);
        }
    }

    /// Arm rules when a plug transitions off→on. Optionally seeds idle
    /// tracking if `seed_power` is already below threshold.
    pub fn on_plug_on(
        &mut self,
        device: &str,
        seed_power: Option<f64>,
        ts: Instant,
    ) {
        for &idx in self.topology.bindings_for_power_below(device) {
            let resolved = &self.topology.bindings()[idx];
            let rule_name = resolved.name.clone();
            if self.suppressed.contains(&rule_name) {
                continue;
            }
            if self.armed.contains(&rule_name) {
                continue;
            }
            self.armed.insert(rule_name.clone());
            if let Some(current_power) = seed_power {
                let threshold = match &resolved.trigger {
                    Trigger::PowerBelow { watts, .. } => *watts,
                    _ => continue,
                };
                if current_power < threshold {
                    tracing::info!(
                        device,
                        rule = %rule_name,
                        power = current_power,
                        threshold,
                        "auto-arm: seeding idle (power already below threshold)"
                    );
                    self.idle_since.insert(rule_name, ts);
                    continue;
                }
            }
            tracing::info!(
                device,
                rule = %rule_name,
                "auto-arm: arming kill switch on off→on transition"
            );
        }
    }

    /// Evaluate a power reading against all `PowerBelow` rules for
    /// `device`. Returns fired kill-switches whose holdoff has elapsed.
    /// Internally handles arming, idle tracking, suppression, and
    /// recovery.
    pub fn evaluate(
        &mut self,
        device: &str,
        power: f64,
        ts: Instant,
    ) -> Vec<KillSwitchFired> {
        let rule_indexes = self.topology.bindings_for_power_below(device).to_vec();
        if rule_indexes.is_empty() {
            return Vec::new();
        }

        // Pre-extract the data we need from the topology so that the
        // loop body can call &mut self methods without conflicting with
        // the immutable topology borrow.
        struct RuleInfo {
            rule_name: String,
            threshold_watts: f64,
            holdoff_secs: u64,
            target: Option<String>,
        }
        let rules: Vec<RuleInfo> = rule_indexes.iter().filter_map(|&idx| {
            let resolved = &self.topology.bindings()[idx];
            match &resolved.trigger {
                Trigger::PowerBelow { watts, for_seconds, .. } => Some(RuleInfo {
                    rule_name: resolved.name.clone(),
                    threshold_watts: *watts,
                    holdoff_secs: *for_seconds,
                    target: resolved.effect.target().map(str::to_string),
                }),
                _ => None,
            }
        }).collect();

        let mut fired = Vec::new();
        for rule in &rules {
            if power < rule.threshold_watts {
                if !self.armed.contains(&rule.rule_name) {
                    tracing::info!(
                        device,
                        rule = %rule.rule_name,
                        power,
                        threshold = rule.threshold_watts,
                        "kill switch: below threshold but not yet armed \
                         (waiting for first above-threshold reading)"
                    );
                } else {
                    if !self.idle_since.contains_key(&rule.rule_name) {
                        tracing::info!(
                            device,
                            rule = %rule.rule_name,
                            power,
                            threshold = rule.threshold_watts,
                            "kill switch: power dropped below threshold, starting holdoff"
                        );
                        self.idle_since.insert(rule.rule_name.clone(), ts);
                    }
                    if let Some(&idle_start) = self.idle_since.get(&rule.rule_name) {
                        if ts.duration_since(idle_start) >= Duration::from_secs(rule.holdoff_secs) {
                            tracing::info!(
                                device,
                                rule = %rule.rule_name,
                                holdoff_secs = rule.holdoff_secs,
                                "kill switch: holdoff elapsed, turning off plug"
                            );
                            self.suppress_all(device);
                            if let Some(target) = &rule.target {
                                fired.push(KillSwitchFired {
                                    device: device.to_string(),
                                    rule_name: rule.rule_name.clone(),
                                    target: target.clone(),
                                });
                            }
                            break;
                        }
                    }
                }
            } else {
                // Power above threshold — arm, clear idle, lift suppression.
                self.armed.insert(rule.rule_name.clone());
                self.suppressed.remove(&rule.rule_name);
                if self.idle_since.remove(&rule.rule_name).is_some() {
                    tracing::info!(
                        device,
                        rule = %rule.rule_name,
                        power,
                        threshold = rule.threshold_watts,
                        "kill switch: power recovered above threshold, resetting holdoff"
                    );
                }
            }
        }
        fired
    }

    /// Tick-based evaluation of pending deadlines. Checks all armed
    /// rules that have an idle timer running and fires those whose
    /// holdoff has elapsed.
    pub fn tick(
        &mut self,
        ts: Instant,
        is_plug_on: &dyn Fn(&str) -> bool,
    ) -> Vec<KillSwitchFired> {
        let actions_snapshot = self.topology.bindings().to_vec();
        let mut fired = Vec::new();
        for resolved in &actions_snapshot {
            let (device, holdoff_secs) = match &resolved.trigger {
                Trigger::PowerBelow { device, for_seconds, .. } => {
                    (device.as_str(), *for_seconds)
                }
                _ => continue,
            };
            if !is_plug_on(device) {
                continue;
            }
            let Some(&idle_start) = self.idle_since.get(&resolved.name) else {
                continue;
            };
            if ts.duration_since(idle_start) >= Duration::from_secs(holdoff_secs) {
                tracing::info!(
                    device,
                    rule = %resolved.name,
                    holdoff_secs,
                    "tick: kill switch holdoff elapsed, turning off plug"
                );
                self.suppress_all(device);
                if let Some(target) = resolved.effect.target() {
                    fired.push(KillSwitchFired {
                        device: device.to_string(),
                        rule_name: resolved.name.clone(),
                        target: target.to_string(),
                    });
                }
            }
        }
        fired
    }

    /// Pre-arm kill-switch rules for every plug that is currently ON.
    /// Called once after startup state refresh.
    ///
    /// `active_plugs` is an iterator of `(device_name, last_power)` for
    /// each plug that is currently on.
    pub fn arm_for_active_plugs<'a>(
        &mut self,
        active_plugs: impl Iterator<Item = (&'a str, Option<f64>)>,
        ts: Instant,
    ) {
        for (plug_name, last_power) in active_plugs {
            for &idx in self.topology.bindings_for_power_below(plug_name) {
                let resolved = &self.topology.bindings()[idx];
                let rule_name = resolved.name.clone();
                if self.suppressed.contains(&rule_name)
                    || self.armed.contains(&rule_name)
                {
                    continue;
                }
                self.armed.insert(rule_name.clone());

                if let Some(power) = last_power {
                    let threshold = match &resolved.trigger {
                        Trigger::PowerBelow { watts, .. } => *watts,
                        _ => continue,
                    };
                    if power < threshold && !self.idle_since.contains_key(&rule_name) {
                        tracing::info!(
                            plug = plug_name,
                            rule = rule_name.as_str(),
                            power,
                            threshold,
                            "startup: pre-arming AND seeding idle \
                             (power already below threshold)"
                        );
                        self.idle_since.insert(rule_name, ts);
                        continue;
                    }
                }

                tracing::info!(
                    plug = plug_name,
                    rule = rule_name.as_str(),
                    "startup: pre-arming kill switch for active plug"
                );
            }
        }
    }

    /// Suppress and clear ALL rules for a device. Called when any
    /// kill-switch fires.
    fn suppress_all(&mut self, device: &str) {
        for &idx in self.topology.bindings_for_power_below(device) {
            let name = &self.topology.bindings()[idx].name;
            self.idle_since.remove(name);
            self.armed.remove(name);
            self.suppressed.insert(name.clone());
        }
    }
}
