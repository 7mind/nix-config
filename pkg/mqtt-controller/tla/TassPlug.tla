---- MODULE TassPlug ----
\* TLA+ formal specification of a single smart plug with TASS
\* (Target/Actual State Separation) and kill switch automation.
\*
\* Covers:
\*   - Target lifecycle: Unset -> Commanded -> Confirmed
\*   - Actual state echoes (on/off + power reading)
\*   - Kill switch state machine: Inactive -> Armed -> Idle -> Suppressed
\*   - Holdoff timer for kill switch firing
\*   - Power recovery from Suppressed state
\*
\* Correspondence to Rust source:
\*   ToggleOn        -> target.set_and_command(On, ..., ts)
\*   ToggleOff       -> target.set_and_command(Off, ..., ts), reset_kill_switches()
\*   EchoOn          -> handle_plug_state(on=true): actual.update(), maybe_confirm(),
\*                      arm_kill_switch_rules()
\*   EchoOff         -> handle_plug_state(on=false): actual.update(),
\*                      reset_kill_switches(), target.set_and_command(Off, Rule, ts)
\*   PowerUpdate(w)  -> handle_plug_state() power path: evaluate_kill_switch()
\*                      Armed + below -> Idle; Idle/Suppressed + above -> Armed
\*   KillSwitchFire  -> evaluate_kill_switch_ticks() / evaluate_kill_switch():
\*                      holdoff elapsed, target=Off, suppress_all_kill_switches()
\*   PowerRecover    -> evaluate_kill_switch(): Suppressed + above -> Armed
\*   Tick            -> clock advancement for holdoff evaluation
\*
\* Simplifications vs. the Rust code:
\*   - Single kill switch rule (no per-rule BTreeMap)
\*   - Power is abstract Nat (0..MaxPower), not f64
\*   - actual_fresh is "Unknown" | "Fresh" (no Stale -- plugs don't go stale)
\*   - No target device indirection (plug controls itself)

EXTENDS Integers

\* =====================================================================
\* Constants
\* =====================================================================

CONSTANTS
    KillThreshold,  \* Nat: power below this triggers idle tracking
    KillHoldoff,    \* Nat: time units power must stay below threshold to fire
    MaxPower,       \* Nat: upper bound for power readings (model checking)
    MaxTime,        \* Nat: upper bound for bounded model checking
    NIL             \* Sentinel: "no value"

\* =====================================================================
\* Variables
\* =====================================================================

VARIABLES
    target_val,     \* "Unset" | "On" | "Off"
    target_phase,   \* "Unset" | "Commanded" | "Confirmed"
    actual_on,      \* BOOLEAN: plug on/off state from device
    actual_power,   \* Nat (0..MaxPower): last power reading
    actual_fresh,   \* "Unknown" | "Fresh"
    ks_state,       \* "Inactive" | "Armed" | "Idle" | "Suppressed"
    ks_idle_since,  \* Nat \cup {NIL}: when idle tracking started
    now             \* Nat: bounded monotonic clock

vars == <<target_val, target_phase, actual_on, actual_power, actual_fresh,
          ks_state, ks_idle_since, now>>

\* =====================================================================
\* Type invariant
\* =====================================================================

TypeOK ==
    /\ target_val   \in {"Unset", "On", "Off"}
    /\ target_phase \in {"Unset", "Commanded", "Confirmed"}
    /\ actual_on    \in BOOLEAN
    /\ actual_power \in 0..MaxPower
    /\ actual_fresh \in {"Unknown", "Fresh"}
    /\ ks_state     \in {"Inactive", "Armed", "Idle", "Suppressed"}
    /\ ks_idle_since \in (0..MaxTime) \cup {NIL}
    /\ now \in 0..MaxTime

\* =====================================================================
\* Helpers
\* =====================================================================

\* Target matches actual on/off state. Used for confirmation logic.
TargetMatchesActual ==
    \/ (target_val = "On"  /\ actual_on = TRUE)
    \/ (target_val = "Off" /\ actual_on = FALSE)

\* =====================================================================
\* Initial state
\* =====================================================================

Init ==
    /\ target_val    = "Unset"
    /\ target_phase  = "Unset"
    /\ actual_on     = FALSE
    /\ actual_power  = 0
    /\ actual_fresh  = "Unknown"
    /\ ks_state      = "Inactive"
    /\ ks_idle_since = NIL
    /\ now           = 0

\* =====================================================================
\* Actions
\* =====================================================================

\* --- Toggle plug on ---
\* Maps to target.set_and_command(On, ..., ts).
ToggleOn ==
    /\ target_val'    = "On"
    /\ target_phase'  = "Commanded"
    /\ UNCHANGED <<actual_on, actual_power, actual_fresh,
                   ks_state, ks_idle_since, now>>

\* --- Toggle plug off ---
\* Maps to target.set_and_command(Off, ..., ts), reset_kill_switches().
\* Off command always resets kill switch to Inactive.
ToggleOff ==
    /\ target_val'    = "Off"
    /\ target_phase'  = "Commanded"
    /\ ks_state'      = "Inactive"
    /\ ks_idle_since' = NIL
    /\ UNCHANGED <<actual_on, actual_power, actual_fresh, now>>

\* --- Device echoes ON ---
\* Maps to handle_plug_state(on=true):
\*   actual.update(on=true, power), maybe_confirm_plug_target(),
\*   arm_kill_switch_rules().
\* When the echo arrives with power, evaluate kill switch arming.
EchoOn ==
    /\ actual_on'    = TRUE
    /\ actual_fresh' = "Fresh"
    \* Arm kill switch on off->on transition.
    \* Mirrors arm_kill_switch_rules(): Inactive -> Armed.
    /\ ks_state' = IF ks_state = "Inactive" THEN "Armed"
                   ELSE ks_state
    /\ ks_idle_since' = ks_idle_since
    \* Confirm target if it matches.
    /\ IF target_val = "On" /\ target_phase = "Commanded"
       THEN target_phase' = "Confirmed"
       ELSE UNCHANGED target_phase
    /\ UNCHANGED <<target_val, actual_power, now>>

\* --- Device echoes OFF ---
\* Maps to handle_plug_state(on=false):
\*   actual.update(on=false), reset_kill_switches(),
\*   target.set_and_command(Off, Rule, ts).
EchoOff ==
    /\ actual_on'     = FALSE
    /\ actual_fresh'  = "Fresh"
    /\ ks_state'      = "Inactive"
    /\ ks_idle_since' = NIL
    \* Off echo always resets target to Off.
    /\ target_val'    = "Off"
    /\ target_phase'  = "Commanded"
    /\ UNCHANGED <<actual_power, now>>

\* --- Power reading update ---
\* Maps to handle_plug_state() power evaluation path.
\* Only fires when plug is on (power readings while off are ignored).
\* Evaluates kill switch transitions based on power vs threshold.
PowerUpdate(w) ==
    /\ actual_on = TRUE
    /\ actual_fresh = "Fresh"
    /\ w \in 0..MaxPower
    /\ actual_power' = w
    /\ IF w < KillThreshold
       THEN \* Below threshold: evaluate kill switch.
            CASE ks_state = "Armed" ->
                    \* Armed -> Idle: start holdoff timer.
                    /\ ks_state'      = "Idle"
                    /\ ks_idle_since' = now
              [] ks_state = "Idle" ->
                    \* Already idle: keep tracking (no reset).
                    /\ UNCHANGED <<ks_state, ks_idle_since>>
              [] ks_state = "Inactive" ->
                    \* Not yet armed: ignore (waiting for above-threshold).
                    /\ UNCHANGED <<ks_state, ks_idle_since>>
              [] ks_state = "Suppressed" ->
                    \* Stay suppressed until power recovers.
                    /\ UNCHANGED <<ks_state, ks_idle_since>>
       ELSE \* Above threshold: arm or recover.
            CASE ks_state = "Suppressed" ->
                    \* Recover from suppression.
                    /\ ks_state'      = "Armed"
                    /\ ks_idle_since' = NIL
              [] ks_state = "Idle" ->
                    \* Power recovered before holdoff elapsed.
                    /\ ks_state'      = "Armed"
                    /\ ks_idle_since' = NIL
              [] ks_state = "Inactive" ->
                    \* First time above threshold: arm.
                    /\ ks_state'      = "Armed"
                    /\ ks_idle_since' = NIL
              [] ks_state = "Armed" ->
                    \* Already armed: stay armed.
                    /\ UNCHANGED <<ks_state, ks_idle_since>>
    /\ UNCHANGED <<target_val, target_phase, actual_on, actual_fresh, now>>

\* --- Kill switch fires ---
\* Maps to evaluate_kill_switch() / evaluate_kill_switch_ticks():
\*   holdoff elapsed, target = Off, ks_state = Suppressed.
\* Preconditions: Idle, holdoff has elapsed.
KillSwitchFire ==
    /\ ks_state = "Idle"
    /\ ks_idle_since # NIL
    /\ now - ks_idle_since >= KillHoldoff
    /\ target_val'    = "Off"
    /\ target_phase'  = "Commanded"
    /\ ks_state'      = "Suppressed"
    /\ ks_idle_since' = NIL
    /\ UNCHANGED <<actual_on, actual_power, actual_fresh, now>>

\* --- Power recovery from suppressed ---
\* Maps to evaluate_kill_switch() Suppressed branch:
\*   power recovers above threshold -> Armed.
\* This is also handled by PowerUpdate, but modeled separately
\* for clarity in the spec. In the actual system, this transition
\* happens within the same power update evaluation.
PowerRecover ==
    /\ ks_state = "Suppressed"
    /\ actual_on = TRUE
    /\ actual_power >= KillThreshold
    /\ ks_state'      = "Armed"
    /\ ks_idle_since' = NIL
    /\ UNCHANGED <<target_val, target_phase, actual_on, actual_power,
                   actual_fresh, now>>

\* --- Clock tick ---
Tick ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ UNCHANGED <<target_val, target_phase, actual_on, actual_power,
                   actual_fresh, ks_state, ks_idle_since>>

\* =====================================================================
\* Next-state relation
\* =====================================================================

Next ==
    \/ ToggleOn
    \/ ToggleOff
    \/ EchoOn
    \/ EchoOff
    \/ \E w \in 0..MaxPower : PowerUpdate(w)
    \/ KillSwitchFire
    \/ PowerRecover
    \/ Tick

\* Weak fairness on Tick so liveness properties work (time always advances).
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick)

\* =====================================================================
\* STATE INVARIANTS (must hold in every reachable state)
\* =====================================================================

\* S1: Kill switch can only be Idle when the plug is on.
\*     If the plug is off, kill switch must be Inactive.
IdleOnlyWhenOn ==
    ks_state = "Idle" => actual_on = TRUE

\* S2: ks_idle_since is set iff ks_state is Idle, and the timestamp
\*     must be in the past.
IdleSinceValid ==
    /\ (ks_state = "Idle") => (ks_idle_since # NIL /\ ks_idle_since <= now)
    /\ (ks_state # "Idle") => (ks_idle_since = NIL)

\* S3: Confirmed target must match actual on/off state.
ConfirmedImpliesMatch ==
    target_phase = "Confirmed" => TargetMatchesActual

\* S4: If target_phase is "Unset", target_val must be "Unset".
UnsetConsistent ==
    target_phase = "Unset" => target_val = "Unset"

\* S5: ks_idle_since timestamp is in the past.
IdleSinceInPast ==
    ks_idle_since # NIL => ks_idle_since <= now

\* S6: Kill switch Armed or Idle requires the plug to be on and fresh.
\*     Inactive and Suppressed can persist across off/on transitions
\*     (Inactive is the reset state; Suppressed survives off in Rust but
\*     in our simplified model it's reset on EchoOff).
KillSwitchRequiresOn ==
    ks_state \in {"Armed", "Idle"} => actual_on = TRUE

\* =====================================================================
\* ACTION PROPERTIES (must hold across every state transition)
\* =====================================================================

\* A1: Kill switch respects holdoff. Idle can only go to Suppressed
\*     (via KillSwitchFire) when the holdoff has elapsed.
KillSwitchRespectsHoldoff ==
    (ks_state = "Idle" /\ ks_state' = "Suppressed")
        => (ks_idle_since # NIL /\ now - ks_idle_since >= KillHoldoff)

KillSwitchRespectsHoldoffProp == [][KillSwitchRespectsHoldoff]_vars

\* A2: Off echo always clears kill switch tracking.
OffClearsKillSwitch ==
    (actual_on /\ ~actual_on')
        => (ks_state' = "Inactive" /\ ks_idle_since' = NIL)

OffClearsKillSwitchProp == [][OffClearsKillSwitch]_vars

\* A3: Off echo always resets target to Off.
OffResetsTarget ==
    (actual_on /\ ~actual_on')
        => target_val' = "Off"

OffResetsTargetProp == [][OffResetsTarget]_vars

====
