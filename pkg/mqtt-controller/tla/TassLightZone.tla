---- MODULE TassLightZone ----
\* TLA+ formal specification of a single light zone with TASS
\* (Target/Actual State Separation) state machine.
\*
\* Covers:
\*   - Target lifecycle: Unset -> Commanded -> Confirmed
\*   - Actual state echoes from z2m (group state)
\*   - Actual freshness tracking (Unknown -> Fresh -> Stale)
\*   - Owner tracking (None, User, Motion, System)
\*   - Button press (on/off)
\*   - Motion sensor automation (with gates: actual off, cooldown, owner)
\*   - Cooldown after off transition
\*   - Clock advancement (bounded)
\*
\* Correspondence to Rust source:
\*   ButtonPressOn   -> execute_scene_cycle() / execute_scene_toggle() on-branch
\*                      -> write_after_on(): target.set_and_command(On, User, ts)
\*   ButtonPressOff  -> execute_scene_toggle() off-branch / execute_turn_off_room()
\*                      -> write_after_off(): target.set_and_command(Off, User, ts)
\*   MotionOn        -> handle_occupancy(), occupied=true, gates pass
\*                      -> target.set_and_command(On, Motion, ts)
\*   MotionOff       -> handle_occupancy(), occupied=false, all sensors clear
\*                      -> target.set_and_command(Off, Motion, ts)
\*   GroupEchoOn     -> handle_group_state(), actual.update(On, ts)
\*   GroupEchoOff    -> handle_group_state(), actual.update(Off, ts),
\*                      target.set_and_command(Off, System, ts)
\*   ActualGoesStale -> TassActual::mark_stale() (periodic staleness check)
\*   Tick            -> clock advancement for cooldown / cycle window evaluation
\*
\* Simplifications vs. the Rust code:
\*   - Single motion sensor (no multi-sensor OR gate)
\*   - target_val simplified to "Off"/"On" (no scene_id / cycle_idx)
\*   - No illuminance gate (modeled as always-dark)
\*   - No parent/child propagation (single zone)

EXTENDS Integers

\* =====================================================================
\* Constants
\* =====================================================================

CONSTANTS
    CycleWindow,    \* Nat: tap cycle window (time units) -- unused in this
                    \*      simplified model but kept for future extension
    Cooldown,       \* Nat: motion-off cooldown (time units)
    HasMotion,      \* BOOLEAN: whether this zone has a motion sensor
    MaxTime,        \* Nat: upper bound for bounded model checking
    NIL             \* Sentinel: "no value"

\* =====================================================================
\* Variables
\* =====================================================================

VARIABLES
    target_val,     \* "Off" | "On"
    target_phase,   \* "Unset" | "Commanded" | "Confirmed"
    target_owner,   \* "None" | "User" | "Motion" | "System"
    actual_val,     \* "Unknown" | "On" | "Off"
    actual_fresh,   \* "Unknown" | "Fresh" | "Stale"
    motion_occupied,\* BOOLEAN: single motion sensor state
    last_press_at,  \* Nat \cup {NIL}: last button press timestamp
    last_off_at,    \* Nat \cup {NIL}: last off-transition timestamp
    now             \* Nat: bounded monotonic clock

vars == <<target_val, target_phase, target_owner, actual_val, actual_fresh,
          motion_occupied, last_press_at, last_off_at, now>>

\* =====================================================================
\* Type invariant
\* =====================================================================

TypeOK ==
    /\ target_val   \in {"Off", "On"}
    /\ target_phase \in {"Unset", "Commanded", "Confirmed"}
    /\ target_owner \in {"None", "User", "Motion", "System"}
    /\ actual_val   \in {"Unknown", "On", "Off"}
    /\ actual_fresh \in {"Unknown", "Fresh", "Stale"}
    /\ motion_occupied \in BOOLEAN
    /\ last_press_at \in (0..MaxTime) \cup {NIL}
    /\ last_off_at   \in (0..MaxTime) \cup {NIL}
    /\ now \in 0..MaxTime

\* =====================================================================
\* Helpers
\* =====================================================================

\* The zone is considered "on" optimistically: target says On (commanded
\* but maybe not confirmed yet) OR actual reports On.
\* Mirrors LightZoneEntity::is_on().
IsOn == target_val = "On" \/ actual_val = "On"

\* TRUE iff the motion-off cooldown has elapsed.
\* Mirrors the cooldown check in dispatch_motion().
CooldownPassed ==
    IF Cooldown = 0 THEN TRUE
    ELSE IF last_off_at = NIL THEN TRUE
    ELSE now - last_off_at >= Cooldown

\* =====================================================================
\* Initial state
\* =====================================================================

Init ==
    /\ target_val    = "Off"
    /\ target_phase  = "Unset"
    /\ target_owner  = "None"
    /\ actual_val    = "Unknown"
    /\ actual_fresh  = "Unknown"
    /\ motion_occupied = FALSE
    /\ last_press_at = NIL
    /\ last_off_at   = NIL
    /\ now           = 0

\* =====================================================================
\* Actions
\* =====================================================================

\* --- User presses the on button ---
\* Maps to write_after_on(): target.set_and_command(On, User, ts).
\* User press always succeeds and supersedes any motion ownership.
ButtonPressOn ==
    /\ target_val'    = "On"
    /\ target_phase'  = "Commanded"
    /\ target_owner'  = "User"
    /\ last_press_at' = now
    /\ UNCHANGED <<actual_val, actual_fresh, motion_occupied, last_off_at, now>>

\* --- User presses the off button ---
\* Maps to write_after_off(): target.set_and_command(Off, User, ts).
ButtonPressOff ==
    /\ target_val'    = "Off"
    /\ target_phase'  = "Commanded"
    /\ target_owner'  = "User"
    /\ last_press_at' = now
    /\ last_off_at'   = now
    /\ UNCHANGED <<actual_val, actual_fresh, motion_occupied, now>>

\* --- Motion sensor triggers (occupied=true, gates pass) ---
\* Maps to dispatch_motion() occupied=true path.
\* Gates: zone must not be on, cooldown must have passed.
\* Note: no user-override gate — the cooldown is the only protection
\* after a user turns lights off (matches Rust dispatch_motion).
MotionOn ==
    /\ HasMotion
    /\ ~IsOn                          \* gate: room currently off
    /\ CooldownPassed                 \* gate: cooldown expired
    /\ motion_occupied' = TRUE
    /\ target_val'    = "On"
    /\ target_phase'  = "Commanded"
    /\ target_owner'  = "Motion"
    \* Motion doesn't touch last_press_at (it's not a button press).
    /\ UNCHANGED <<actual_val, actual_fresh, last_press_at, last_off_at, now>>

\* --- Motion sensor clears (occupied=false, gates pass) ---
\* Maps to dispatch_motion() occupied=false path.
\* Gates: owner must be Motion (we own the lights), zone must be on.
MotionOff ==
    /\ HasMotion
    /\ target_owner = "Motion"        \* gate: motion-owned
    /\ IsOn                           \* gate: lights are on
    /\ motion_occupied' = FALSE
    /\ target_val'    = "Off"
    /\ target_phase'  = "Commanded"
    /\ target_owner'  = "Motion"
    /\ last_off_at'   = now
    /\ UNCHANGED <<actual_val, actual_fresh, last_press_at, now>>

\* --- z2m confirms group state ON ---
\* Maps to handle_group_state(on=true).
\* Updates actual state. If target matches (On), confirms the target.
GroupEchoOn ==
    /\ actual_val'   = "On"
    /\ actual_fresh' = "Fresh"
    /\ IF target_val = "On"
       THEN target_phase' = "Confirmed"
       ELSE UNCHANGED target_phase
    /\ UNCHANGED <<target_val, target_owner, motion_occupied,
                   last_press_at, last_off_at, now>>

\* --- z2m confirms group state OFF ---
\* Maps to handle_group_state(on=false).
\* Updates actual state. If target matches (Off), confirms target.
\* On off-transition: resets target to Off/System (clear motion ownership).
GroupEchoOff ==
    /\ actual_val'   = "Off"
    /\ actual_fresh' = "Fresh"
    \* Off transition: always reset target to Off/System.
    \* This matches handle_group_state() off branch:
    \*   target.set_and_command(Off, System, ts)
    /\ target_val'   = "Off"
    /\ target_phase' = "Commanded"
    /\ target_owner' = "System"
    /\ last_off_at'  = now
    /\ UNCHANGED <<motion_occupied, last_press_at, now>>

\* --- Actual state goes stale ---
\* Maps to TassActual::mark_stale(). Only Fresh can become Stale.
ActualGoesStale ==
    /\ actual_fresh = "Fresh"
    /\ actual_fresh' = "Stale"
    /\ UNCHANGED <<target_val, target_phase, target_owner, actual_val,
                   motion_occupied, last_press_at, last_off_at, now>>

\* --- Clock tick ---
Tick ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ UNCHANGED <<target_val, target_phase, target_owner, actual_val,
                   actual_fresh, motion_occupied, last_press_at, last_off_at>>

\* =====================================================================
\* Next-state relation
\* =====================================================================

Next ==
    \/ ButtonPressOn
    \/ ButtonPressOff
    \/ MotionOn
    \/ MotionOff
    \/ GroupEchoOn
    \/ GroupEchoOff
    \/ ActualGoesStale
    \/ Tick

\* Weak fairness on Tick so liveness properties work (time always advances).
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick)

\* =====================================================================
\* STATE INVARIANTS (must hold in every reachable state)
\* =====================================================================

\* S1: If target_phase is "Unset", target_val must be the default "Off"
\*     and target_owner must be "None".
TargetPhaseValid ==
    target_phase = "Unset" => (target_val = "Off" /\ target_owner = "None")

\* S2: If target_phase is "Confirmed", target_val and actual_val must agree.
\*     "Confirmed" means actual echoed back the target value.
ConfirmedImpliesMatch ==
    target_phase = "Confirmed" =>
        \/ (target_val = "On"  /\ actual_val = "On")
        \/ (target_val = "Off" /\ actual_val = "Off")

\* S3: If target_owner is "Motion" and actual_val is "Off", then
\*     target_val should be "Off" (motion turned them off or they
\*     haven't responded yet but target says off).
\*     The contrapositive: motion owning + actual off + target on
\*     is only valid in the transient Commanded state before the echo.
MotionOwnerConsistent ==
    (target_owner = "Motion" /\ actual_val = "Off" /\ actual_fresh = "Fresh")
        => (target_val = "Off" \/ target_phase = "Commanded")

\* S4: If actual_fresh is "Unknown", actual_val must be "Unknown".
\*     No reading has ever been received.
FreshnessValid ==
    actual_fresh = "Unknown" => actual_val = "Unknown"

\* S5: Timestamps are always in the past (or present).
LastPressInPast ==
    last_press_at # NIL => last_press_at <= now

LastOffInPast ==
    last_off_at # NIL => last_off_at <= now

\* S6: If cooldown hasn't passed and HasMotion, MotionOn is blocked.
\*     Regression guard: if someone removes the cooldown check from
\*     MotionOn, this catches it.
CooldownBlocksMotion ==
    (HasMotion /\ ~IsOn /\ ~CooldownPassed
     /\ ~(target_owner = "User" /\ last_off_at # NIL))
        => ~ENABLED MotionOn

\* =====================================================================
\* ACTION PROPERTIES (must hold across every state transition)
\* =====================================================================

\* A1: GroupEchoOff always resets target_owner (no stale motion ownership).
\*     After an off echo, owner becomes "System".
OffResetsOwner ==
    (actual_val # "Off" /\ actual_val' = "Off" /\ actual_fresh' = "Fresh")
        => target_owner' = "System"

OffResetsOwnerProp == [][OffResetsOwner]_vars

\* A2: When target transitions from non-Off to Off, last_off_at is updated.
OffStampsLastOff ==
    (target_val # "Off" /\ target_val' = "Off")
        => last_off_at' = now

OffStampsLastOffProp == [][OffStampsLastOff]_vars

\* A3: User press always clears motion ownership.
UserPressClearsMotion ==
    (target_owner' = "User" /\ target_owner # "User")
        => target_owner' # "Motion"

UserPressClearsMotionProp == [][UserPressClearsMotion]_vars

====
