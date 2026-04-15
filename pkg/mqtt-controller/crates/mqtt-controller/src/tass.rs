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
    use std::time::Duration;

    // ---- TassTarget tests ----

    #[test]
    fn target_starts_unset() {
        let t: TassTarget<u8> = TassTarget::new();
        assert_eq!(t.phase(), TargetPhase::Unset);
        assert!(t.value().is_none());
        assert!(t.owner().is_none());
        assert!(t.since().is_none());
        assert!(t.is_unset());
    }

    #[test]
    fn target_set_and_command_lifecycle() {
        let mut t: TassTarget<String> = TassTarget::new();
        let ts = Instant::now();

        t.set_and_command("on".into(), Owner::User, ts);
        assert_eq!(t.phase(), TargetPhase::Commanded);
        assert_eq!(t.value(), Some(&"on".into()));
        assert_eq!(t.owner(), Some(Owner::User));
        assert_eq!(t.since(), Some(ts));
        assert!(!t.is_unset());

        t.confirm(ts);
        assert_eq!(t.phase(), TargetPhase::Confirmed);
        assert_eq!(t.value(), Some(&"on".into())); // value preserved

        // New target overrides confirmed
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
        assert_eq!(t.value(), Some(&42));

        let ts2 = ts + Duration::from_secs(1);
        t.command(ts2);
        assert_eq!(t.phase(), TargetPhase::Commanded);
        assert_eq!(t.since(), Some(ts2)); // since updated
    }

    #[test]
    #[should_panic(expected = "command() requires Pending phase")]
    fn target_command_from_unset_panics() {
        let mut t: TassTarget<u8> = TassTarget::new();
        t.command(Instant::now());
    }

    #[test]
    #[should_panic(expected = "confirm() requires Commanded, Stale, or Confirmed phase")]
    fn target_confirm_from_unset_panics() {
        let mut t: TassTarget<u8> = TassTarget::new();
        t.confirm(Instant::now());
    }

    #[test]
    #[should_panic(expected = "confirm() requires Commanded, Stale, or Confirmed phase")]
    fn target_confirm_from_pending_panics() {
        let mut t: TassTarget<u8> = TassTarget::new();
        let ts = Instant::now();
        t.set(42, Owner::User, ts);
        t.confirm(ts);
    }

    #[test]
    fn target_confirm_from_confirmed_is_idempotent() {
        let mut t: TassTarget<u8> = TassTarget::new();
        let ts = Instant::now();
        t.set_and_command(1, Owner::User, ts);
        t.confirm(ts);
        t.confirm(ts); // no panic
        assert_eq!(t.phase(), TargetPhase::Confirmed);
    }

    #[test]
    fn target_mark_stale_from_commanded() {
        let mut t: TassTarget<u8> = TassTarget::new();
        let ts = Instant::now();
        t.set_and_command(42, Owner::User, ts);
        t.mark_stale();
        assert_eq!(t.phase(), TargetPhase::Stale);
        assert_eq!(t.value(), Some(&42)); // value preserved
        assert_eq!(t.owner(), Some(Owner::User)); // owner preserved
    }

    #[test]
    fn target_mark_stale_noop_when_not_commanded() {
        let mut t: TassTarget<u8> = TassTarget::new();
        t.mark_stale(); // from Unset — no-op
        assert_eq!(t.phase(), TargetPhase::Unset);

        let ts = Instant::now();
        t.set_and_command(1, Owner::User, ts);
        t.confirm(ts);
        t.mark_stale(); // from Confirmed — no-op
        assert_eq!(t.phase(), TargetPhase::Confirmed);
    }

    #[test]
    fn target_confirm_from_stale_succeeds() {
        let mut t: TassTarget<u8> = TassTarget::new();
        let ts = Instant::now();
        t.set_and_command(1, Owner::User, ts);
        t.mark_stale();
        assert_eq!(t.phase(), TargetPhase::Stale);
        t.confirm(ts); // late echo — should work
        assert_eq!(t.phase(), TargetPhase::Confirmed);
    }

    #[test]
    fn target_set_and_command_overwrites_stale() {
        let mut t: TassTarget<u8> = TassTarget::new();
        let ts = Instant::now();
        t.set_and_command(1, Owner::User, ts);
        t.mark_stale();
        t.set_and_command(2, Owner::Motion, ts); // overwrite stale
        assert_eq!(t.phase(), TargetPhase::Commanded);
        assert_eq!(t.value(), Some(&2));
    }

    #[test]
    fn target_is_actionable() {
        let mut t: TassTarget<u8> = TassTarget::new();
        assert!(!t.is_actionable()); // Unset

        let ts = Instant::now();
        t.set(1, Owner::User, ts);
        assert!(t.is_actionable()); // Pending

        t.command(ts);
        assert!(t.is_actionable()); // Commanded

        t.mark_stale();
        assert!(!t.is_actionable()); // Stale

        t.confirm(ts);
        assert!(!t.is_actionable()); // Confirmed
    }

    #[test]
    #[should_panic(expected = "command() requires Pending phase")]
    fn target_command_from_commanded_panics() {
        let mut t: TassTarget<u8> = TassTarget::new();
        let ts = Instant::now();
        t.set_and_command(1, Owner::User, ts);
        t.command(ts); // already Commanded
    }

    #[test]
    fn target_set_overwrites_previous_pending() {
        let mut t: TassTarget<u8> = TassTarget::new();
        let ts = Instant::now();

        t.set(1, Owner::User, ts);
        assert_eq!(t.value(), Some(&1));

        t.set(2, Owner::Motion, ts);
        assert_eq!(t.value(), Some(&2));
        assert_eq!(t.owner(), Some(Owner::Motion));
        assert_eq!(t.phase(), TargetPhase::Pending);
    }

    #[test]
    fn target_confirm_from_commanded_preserves_value_and_owner() {
        let mut t: TassTarget<&str> = TassTarget::new();
        let ts = Instant::now();

        t.set_and_command("hello", Owner::WebUI, ts);
        let ts2 = ts + Duration::from_secs(1);
        t.confirm(ts2);

        assert_eq!(t.value(), Some(&"hello"));
        assert_eq!(t.owner(), Some(Owner::WebUI));
        assert_eq!(t.since(), Some(ts2));
    }

    #[test]
    fn target_since_tracks_each_transition() {
        let mut t: TassTarget<u8> = TassTarget::new();
        let t0 = Instant::now();
        let t1 = t0 + Duration::from_millis(100);
        let t2 = t0 + Duration::from_millis(200);

        t.set(1, Owner::User, t0);
        assert_eq!(t.since(), Some(t0));

        t.command(t1);
        assert_eq!(t.since(), Some(t1));

        t.confirm(t2);
        assert_eq!(t.since(), Some(t2));
    }

    // ---- TassActual tests ----

    #[test]
    fn actual_starts_unknown() {
        let a: TassActual<bool> = TassActual::new();
        assert_eq!(a.freshness(), ActualFreshness::Unknown);
        assert!(!a.is_known());
        assert!(a.value().is_none());
        assert!(a.since().is_none());
    }

    #[test]
    fn actual_update_transitions_to_fresh() {
        let mut a: TassActual<i32> = TassActual::new();
        let ts = Instant::now();

        a.update(42, ts);
        assert_eq!(a.freshness(), ActualFreshness::Fresh);
        assert!(a.is_known());
        assert_eq!(a.value(), Some(&42));
        assert_eq!(a.since(), Some(ts));
    }

    #[test]
    fn actual_mark_stale_from_fresh() {
        let mut a: TassActual<bool> = TassActual::new();
        let ts = Instant::now();

        a.update(true, ts);
        a.mark_stale();

        assert_eq!(a.freshness(), ActualFreshness::Stale);
        assert_eq!(a.value(), Some(&true)); // value preserved
        assert!(a.is_known()); // still known, just stale
    }

    #[test]
    fn actual_mark_stale_noop_when_unknown() {
        let mut a: TassActual<u8> = TassActual::new();
        a.mark_stale();
        assert_eq!(a.freshness(), ActualFreshness::Unknown);
    }

    #[test]
    fn actual_mark_stale_noop_when_already_stale() {
        let mut a: TassActual<u8> = TassActual::new();
        let ts = Instant::now();

        a.update(1, ts);
        a.mark_stale();
        a.mark_stale(); // no-op

        assert_eq!(a.freshness(), ActualFreshness::Stale);
    }

    #[test]
    fn actual_update_after_stale_restores_fresh() {
        let mut a: TassActual<bool> = TassActual::new();
        let ts = Instant::now();

        a.update(true, ts);
        a.mark_stale();

        let ts2 = ts + Duration::from_secs(1);
        a.update(false, ts2);

        assert_eq!(a.freshness(), ActualFreshness::Fresh);
        assert_eq!(a.value(), Some(&false));
        assert_eq!(a.since(), Some(ts2));
    }

    #[test]
    fn actual_value_mut() {
        let mut a: TassActual<Vec<u8>> = TassActual::new();
        let ts = Instant::now();

        a.update(vec![1], ts);
        a.value_mut().unwrap().push(2);
        assert_eq!(a.value(), Some(&vec![1, 2]));
    }

    #[test]
    fn actual_repeated_updates_stay_fresh() {
        let mut a: TassActual<u8> = TassActual::new();
        let ts = Instant::now();

        a.update(1, ts);
        a.update(2, ts + Duration::from_millis(10));
        a.update(3, ts + Duration::from_millis(20));

        assert_eq!(a.freshness(), ActualFreshness::Fresh);
        assert_eq!(a.value(), Some(&3));
    }

    // ---- Display tests ----

    #[test]
    fn target_phase_display() {
        assert_eq!(TargetPhase::Unset.to_string(), "unset");
        assert_eq!(TargetPhase::Pending.to_string(), "pending");
        assert_eq!(TargetPhase::Commanded.to_string(), "commanded");
        assert_eq!(TargetPhase::Stale.to_string(), "stale");
        assert_eq!(TargetPhase::Confirmed.to_string(), "confirmed");
    }

    #[test]
    fn actual_freshness_display() {
        assert_eq!(ActualFreshness::Unknown.to_string(), "unknown");
        assert_eq!(ActualFreshness::Fresh.to_string(), "fresh");
        assert_eq!(ActualFreshness::Stale.to_string(), "stale");
    }

    #[test]
    fn owner_display() {
        assert_eq!(Owner::User.to_string(), "user");
        assert_eq!(Owner::Motion.to_string(), "motion");
        assert_eq!(Owner::Schedule.to_string(), "schedule");
        assert_eq!(Owner::WebUI.to_string(), "webui");
        assert_eq!(Owner::System.to_string(), "system");
        assert_eq!(Owner::Rule.to_string(), "rule");
    }

    // ---- Default tests ----

    #[test]
    fn target_default_is_unset() {
        let t: TassTarget<u8> = TassTarget::default();
        assert!(t.is_unset());
    }

    #[test]
    fn actual_default_is_unknown() {
        let a: TassActual<u8> = TassActual::default();
        assert_eq!(a.freshness(), ActualFreshness::Unknown);
    }
}
