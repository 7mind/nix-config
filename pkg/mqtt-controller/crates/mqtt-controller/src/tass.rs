//! Core TASS (Target/Actual State Separation) types.
//!
//! Every controllable entity is represented as:
//!   (TargetState + TargetPhase + Owner) + (ActualState + ActualFreshness)
//!
//! Read-only entities (sensors) have only the actual half.

use std::fmt;
use std::time::Instant;

/// Phase of a target state lifecycle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TargetPhase {
    /// No target has been set. Entity is passive.
    Unset,
    /// Target set, command not yet emitted (e.g., blocked by constraint).
    Pending,
    /// Command emitted. Awaiting actual state confirmation.
    Commanded,
    /// Actual state reading confirms the target.
    Confirmed,
}

impl fmt::Display for TargetPhase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unset => write!(f, "unset"),
            Self::Pending => write!(f, "pending"),
            Self::Commanded => write!(f, "commanded"),
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

    /// Mark target as Confirmed (actual state matches target).
    pub fn confirm(&mut self, ts: Instant) {
        self.phase = TargetPhase::Confirmed;
        self.since = Some(ts);
    }

    pub fn value(&self) -> Option<&T> {
        self.value.as_ref()
    }

    pub fn value_mut(&mut self) -> Option<&mut T> {
        self.value.as_mut()
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
mod tests {
    use super::*;

    #[test]
    fn target_lifecycle() {
        let mut t: TassTarget<String> = TassTarget::new();
        assert_eq!(t.phase(), TargetPhase::Unset);
        assert!(t.value().is_none());
        assert!(t.is_unset());

        let ts = Instant::now();
        t.set_and_command("on".into(), Owner::User, ts);
        assert_eq!(t.phase(), TargetPhase::Commanded);
        assert_eq!(t.value(), Some(&"on".into()));
        assert_eq!(t.owner(), Some(Owner::User));
        assert!(!t.is_unset());

        t.confirm(ts);
        assert_eq!(t.phase(), TargetPhase::Confirmed);

        // New target resets to Commanded
        t.set_and_command("off".into(), Owner::Rule, ts);
        assert_eq!(t.phase(), TargetPhase::Commanded);
        assert_eq!(t.value(), Some(&"off".into()));
        assert_eq!(t.owner(), Some(Owner::Rule));
    }

    #[test]
    fn target_pending_then_command() {
        let mut t: TassTarget<u8> = TassTarget::new();
        let ts = Instant::now();
        t.set(42, Owner::Schedule, ts);
        assert_eq!(t.phase(), TargetPhase::Pending);

        t.command(ts);
        assert_eq!(t.phase(), TargetPhase::Commanded);
    }

    #[test]
    #[should_panic(expected = "command() requires Pending phase")]
    fn target_command_from_wrong_phase_panics() {
        let mut t: TassTarget<u8> = TassTarget::new();
        t.command(Instant::now());
    }

    #[test]
    fn actual_lifecycle() {
        let mut a: TassActual<bool> = TassActual::new();
        assert_eq!(a.freshness(), ActualFreshness::Unknown);
        assert!(!a.is_known());
        assert!(a.value().is_none());

        let ts = Instant::now();
        a.update(true, ts);
        assert_eq!(a.freshness(), ActualFreshness::Fresh);
        assert!(a.is_known());
        assert_eq!(a.value(), Some(&true));

        a.mark_stale();
        assert_eq!(a.freshness(), ActualFreshness::Stale);
        assert_eq!(a.value(), Some(&true)); // value preserved

        // New reading restores Fresh
        a.update(false, ts);
        assert_eq!(a.freshness(), ActualFreshness::Fresh);
        assert_eq!(a.value(), Some(&false));
    }

    #[test]
    fn actual_mark_stale_noop_when_unknown() {
        let mut a: TassActual<u8> = TassActual::new();
        a.mark_stale();
        assert_eq!(a.freshness(), ActualFreshness::Unknown);
    }
}
