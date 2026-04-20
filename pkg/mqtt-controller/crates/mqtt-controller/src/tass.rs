//! Core TASS (Target/Actual State Separation) types.
//!
//! Every controllable entity is represented as:
//!   (TargetState + TargetPhase + Owner) + (ActualState + ActualFreshness)
//!
//! Read-only entities (sensors) have only the actual half.

use std::fmt;
use std::time::{Duration, Instant};

/// Phase of a target state lifecycle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TargetPhase {
    /// No target has been set. Entity is passive.
    Unset,
    /// Target set, command not yet emitted (e.g., blocked by constraint).
    Pending,
    /// Command emitted. Awaiting actual state confirmation.
    Commanded,
    /// Command was emitted but confirmation never arrived within the
    /// staleness threshold. The target value is preserved (UI shows it
    /// as stale). The next user action will overwrite with a fresh
    /// Commanded target.
    Stale,
    /// Actual state reading confirms the target.
    Confirmed,
}

impl fmt::Display for TargetPhase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unset => write!(f, "unset"),
            Self::Pending => write!(f, "pending"),
            Self::Commanded => write!(f, "commanded"),
            Self::Stale => write!(f, "stale"),
            Self::Confirmed => write!(f, "confirmed"),
        }
    }
}

/// How recent/reliable an actual state reading is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ActualFreshness {
    /// No reading has ever been received.
    Unknown,
    /// Recent reading available.
    Fresh,
    /// Reading older than entity-specific threshold.
    Stale,
}

impl fmt::Display for ActualFreshness {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unknown => write!(f, "unknown"),
            Self::Fresh => write!(f, "fresh"),
            Self::Stale => write!(f, "stale"),
        }
    }
}

/// Who or what set the current target.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Owner {
    User,
    Motion,
    Schedule,
    WebUI,
    System,
    /// An automation rule (kill switch, pressure group, etc.)
    Rule,
}

impl fmt::Display for Owner {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::User => write!(f, "user"),
            Self::Motion => write!(f, "motion"),
            Self::Schedule => write!(f, "schedule"),
            Self::WebUI => write!(f, "webui"),
            Self::System => write!(f, "system"),
            Self::Rule => write!(f, "rule"),
        }
    }
}

/// Target state with lifecycle tracking.
///
/// When phase is [`TargetPhase::Unset`], value/owner/since are `None`.
/// Once a target is set, the entity stays in the lifecycle (no returning
/// to Unset).
#[derive(Debug, Clone)]
pub struct TassTarget<T> {
    value: Option<T>,
    phase: TargetPhase,
    owner: Option<Owner>,
    since: Option<Instant>,
}

impl<T> TassTarget<T> {
    pub fn new() -> Self {
        Self {
            value: None,
            phase: TargetPhase::Unset,
            owner: None,
            since: None,
        }
    }

    /// Set target value without emitting command. Phase → Pending.
    /// Used when command emission is deferred (e.g., heating min_pause).
    pub fn set(&mut self, value: T, owner: Owner, ts: Instant) {
        self.value = Some(value);
        self.phase = TargetPhase::Pending;
        self.owner = Some(owner);
        self.since = Some(ts);
    }

    /// Advance from Pending to Commanded (command was emitted).
    pub fn command(&mut self, ts: Instant) {
        assert_eq!(
            self.phase,
            TargetPhase::Pending,
            "command() requires Pending phase, got {:?}",
            self.phase
        );
        self.phase = TargetPhase::Commanded;
        self.since = Some(ts);
    }

    /// Set target value and immediately mark as Commanded.
    /// For fire-and-forget systems where command emission is synchronous
    /// with effect processing.
    pub fn set_and_command(&mut self, value: T, owner: Owner, ts: Instant) {
        self.value = Some(value);
        self.phase = TargetPhase::Commanded;
        self.owner = Some(owner);
        self.since = Some(ts);
    }

    /// Adopt a value without emitting a command: set `value` + `owner` and
    /// mark phase `Confirmed`. Use when the controller is matching target
    /// to an already-observed actual state (cold-start seed, healing a
    /// stale target, etc). Contrast with [`Self::set_and_command`] which
    /// transitions to `Commanded` and expects a later actual echo.
    ///
    /// Phase invariant (debug-asserted): callers must only adopt over
    /// `Unset`, `Stale`, or `Confirmed` — adopting over `Commanded` or
    /// `Pending` would race a legitimate in-flight command and silently
    /// drop it.
    pub fn adopt(&mut self, value: T, owner: Owner, ts: Instant) {
        debug_assert!(
            matches!(
                self.phase,
                TargetPhase::Unset | TargetPhase::Stale | TargetPhase::Confirmed
            ),
            "adopt() requires Unset/Stale/Confirmed (would race an in-flight command), got {:?}",
            self.phase
        );
        self.value = Some(value);
        self.phase = TargetPhase::Confirmed;
        self.owner = Some(owner);
        self.since = Some(ts);
    }

    /// Reassign only the owner, leaving value and phase untouched.
    /// No-op if the target has no value yet (Unset has no ownership to
    /// reassign). Use when a latched claim needs to be released or
    /// handed over to a different owner without emitting a command.
    ///
    /// `since` is refreshed ONLY when the phase has no in-flight
    /// command tied to it (Confirmed / Stale). For `Commanded` and
    /// `Pending` the `since` field is what the periodic staleness sweep
    /// uses to detect dropped commands — refreshing it on an owner
    /// handover would mask a lost command indefinitely (e.g. repeated
    /// off-only motion-on re-publishes would keep resetting the
    /// 10s-stale clock on a user's un-echoed scene_recall).
    pub fn reassign_owner(&mut self, owner: Owner, ts: Instant) {
        if self.value.is_none() {
            return;
        }
        self.owner = Some(owner);
        match self.phase {
            TargetPhase::Commanded | TargetPhase::Pending => {
                // Preserve the original lifecycle timestamp.
            }
            TargetPhase::Confirmed | TargetPhase::Stale | TargetPhase::Unset => {
                self.since = Some(ts);
            }
        }
    }

    /// Mark target as Confirmed (actual state matches target).
    /// Valid from Commanded, Stale, or Confirmed (idempotent). A late
    /// echo arriving after staleness should still confirm. Panics from
    /// Unset or Pending.
    pub fn confirm(&mut self, ts: Instant) {
        assert!(
            matches!(
                self.phase,
                TargetPhase::Commanded | TargetPhase::Stale | TargetPhase::Confirmed
            ),
            "confirm() requires Commanded, Stale, or Confirmed phase, got {:?}",
            self.phase
        );
        self.phase = TargetPhase::Confirmed;
        self.since = Some(ts);
    }

    /// Mark a Commanded target as Stale (confirmation never arrived
    /// within the expected window). No-op if not Commanded.
    pub fn mark_stale(&mut self) {
        if self.phase == TargetPhase::Commanded {
            self.phase = TargetPhase::Stale;
        }
    }

    /// If `phase` is Commanded and `since` is older than `threshold`,
    /// mark stale and return `true`. Otherwise leave the phase alone
    /// and return `false`. Used by the periodic staleness sweep.
    pub fn mark_stale_if_old(&mut self, now: Instant, threshold: Duration) -> bool {
        if self.phase == TargetPhase::Commanded
            && self.since.is_some_and(|s| now.duration_since(s) >= threshold)
        {
            self.phase = TargetPhase::Stale;
            true
        } else {
            false
        }
    }

    /// True if the target is in a state where the system is actively
    /// waiting for something (Commanded or Pending). Stale targets
    /// are no longer actionable — the system gave up waiting.
    pub fn is_actionable(&self) -> bool {
        matches!(self.phase, TargetPhase::Commanded | TargetPhase::Pending)
    }

    pub fn value(&self) -> Option<&T> {
        self.value.as_ref()
    }

    pub fn phase(&self) -> TargetPhase {
        self.phase
    }

    pub fn owner(&self) -> Option<Owner> {
        self.owner
    }

    pub fn since(&self) -> Option<Instant> {
        self.since
    }

    pub fn is_unset(&self) -> bool {
        self.phase == TargetPhase::Unset
    }
}

impl<T> Default for TassTarget<T> {
    fn default() -> Self {
        Self::new()
    }
}

/// Actual state with freshness tracking.
///
/// When freshness is [`ActualFreshness::Unknown`], value/since are `None`.
/// Even when [`ActualFreshness::Stale`], the last known value is preserved
/// so the UI can show "last known: X, N minutes ago (stale)".
#[derive(Debug, Clone)]
pub struct TassActual<T> {
    value: Option<T>,
    freshness: ActualFreshness,
    since: Option<Instant>,
}

impl<T> TassActual<T> {
    pub fn new() -> Self {
        Self {
            value: None,
            freshness: ActualFreshness::Unknown,
            since: None,
        }
    }

    /// Update with a new reading. Freshness → Fresh.
    pub fn update(&mut self, value: T, ts: Instant) {
        self.value = Some(value);
        self.freshness = ActualFreshness::Fresh;
        self.since = Some(ts);
    }

    /// Mark current reading as stale (time threshold exceeded).
    /// No-op if freshness is Unknown.
    pub fn mark_stale(&mut self) {
        if self.freshness == ActualFreshness::Fresh {
            self.freshness = ActualFreshness::Stale;
        }
    }

    /// If `freshness` is Fresh and `since` is older than `threshold`,
    /// mark stale and return `true`. Otherwise leave it alone and
    /// return `false`. Used by the periodic actual-staleness sweep.
    pub fn mark_stale_if_old(&mut self, now: Instant, threshold: Duration) -> bool {
        if self.freshness == ActualFreshness::Fresh
            && self.since.is_some_and(|s| now.duration_since(s) >= threshold)
        {
            self.freshness = ActualFreshness::Stale;
            true
        } else {
            false
        }
    }

    pub fn value(&self) -> Option<&T> {
        self.value.as_ref()
    }

    pub fn value_mut(&mut self) -> Option<&mut T> {
        self.value.as_mut()
    }

    pub fn freshness(&self) -> ActualFreshness {
        self.freshness
    }

    pub fn is_known(&self) -> bool {
        self.freshness != ActualFreshness::Unknown
    }

    pub fn since(&self) -> Option<Instant> {
        self.since
    }
}

impl<T> Default for TassActual<T> {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
#[path = "tass_tests.rs"]
mod tests;
