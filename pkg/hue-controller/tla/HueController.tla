---- MODULE HueController ----
\* TLA+ formal specification of the hue-controller state machine.
\*
\* Covers:
\*   - Room state: motion sensors (multi-sensor OR/AND gates, illuminance
\*     gate, cooldown), wall switches (pure scene cycle + dedicated off),
\*     tap buttons (three-branch: fresh-on / cycle / expire), parent-child
\*     propagation, group state echo reconciliation, startup seeding.
\*   - Plug state: toggle, kill switch (power-below holdoff).
\*
\* Designed for exhaustive model checking with TLC.
\*
\* Correspondence to Rust source (controller.rs):
\*   MotionOnFire       -> dispatch_motion(), occupied=true, gates pass
\*   MotionOnBlock      -> dispatch_motion(), occupied=true, gates block
\*   MotionOffFire      -> dispatch_motion(), occupied=false, gates pass
\*   MotionOffBlock     -> dispatch_motion(), occupied=false, gates block
\*   WallSwitchOn       -> wall_switch_on_press()
\*   WallSwitchOff      -> dispatch_switch(OffPressRelease)
\*   TapFreshOn         -> tap_press(), branch 1
\*   TapCycle           -> tap_press(), branch 2
\*   TapExpire          -> tap_press(), branch 3
\*   GroupStateOn       -> handle_group_state(), off->on
\*   GroupStateOff      -> handle_group_state(), on->off
\*   PlugToggle         -> execute_effect(Toggle)
\*   PlugPowerDrop      -> handle_plug_state(), below threshold
\*   PlugPowerRecover   -> handle_plug_state(), above threshold
\*   KillSwitch         -> handle_tick() / handle_plug_state(), holdoff elapsed
\*   PlugExternalOff    -> handle_plug_state(), plug turned off
\*   TurnOffAllZones    -> execute_effect(TurnOffAllZones)
\*   StartupSeed        -> seed_motion_ownership_for_lit_rooms()

EXTENDS Integers, FiniteSets

\* =====================================================================
\* Constants
\* =====================================================================

CONSTANTS
    Rooms,              \* Set of room identifiers
    Sensors,            \* [Rooms -> SUBSET AllSensorNames]
    NumScenes,          \* [Rooms -> Nat >= 1] scenes per room
    Parent,             \* [Rooms -> Rooms \cup {NIL}]
    Cooldown,           \* [Rooms -> Nat] motion-off cooldown (time units)
    HasLuxGate,         \* [Rooms -> BOOLEAN] room has illuminance gate?
    CycleWindow,        \* Nat: tap cycle window (time units)
    RoomHasSwitch,      \* [Rooms -> BOOLEAN]
    RoomHasTap,         \* [Rooms -> BOOLEAN]
    Plugs,              \* Set of plug identifiers
    KillHoldoff,        \* [Plugs -> Nat] kill-switch holdoff (time units)
    MaxTime,            \* Nat: upper bound for bounded model checking
    NIL                 \* Sentinel: "no value"

\* =====================================================================
\* Derived operators
\* =====================================================================

AllSensors == UNION {Sensors[r] : r \in Rooms}

\* Direct children of room r. Sufficient for the 2-level hierarchy we model.
Descendants(r) == {c \in Rooms : Parent[c] = r}

\* =====================================================================
\* Variables
\* =====================================================================

VARIABLES
    pon,        \* [Rooms -> BOOLEAN]           physically_on
    mown,       \* [Rooms -> BOOLEAN]           motion_owned
    cidx,       \* [Rooms -> Nat]               cycle_idx
    lpa,        \* [Rooms -> Nat \cup {NIL}]    last_press_at
    loa,        \* [Rooms -> Nat \cup {NIL}]    last_off_at
    mact,       \* [AllSensors -> BOOLEAN]       motion_active (per sensor)
    pOn,        \* [Plugs -> BOOLEAN]            plug on/off
    pidle,      \* [Plugs -> Nat \cup {NIL}]    plug idle_since
    now,        \* Nat                           monotonic clock
    started     \* BOOLEAN                       startup seed complete?

roomVars == <<pon, mown, cidx, lpa, loa, mact>>
plugVars == <<pOn, pidle>>
vars == <<pon, mown, cidx, lpa, loa, mact, pOn, pidle, now, started>>

\* =====================================================================
\* Type invariant
\* =====================================================================

TypeOK ==
    /\ pon  \in [Rooms -> BOOLEAN]
    /\ mown \in [Rooms -> BOOLEAN]
    /\ \A r \in Rooms : cidx[r] \in 0..(NumScenes[r] - 1)
    /\ \A r \in Rooms : lpa[r]  \in (0..MaxTime) \cup {NIL}
    /\ \A r \in Rooms : loa[r]  \in (0..MaxTime) \cup {NIL}
    /\ mact \in [AllSensors -> BOOLEAN]
    /\ pOn  \in [Plugs -> BOOLEAN]
    /\ \A p \in Plugs : pidle[p] \in (0..MaxTime) \cup {NIL}
    /\ now  \in 0..MaxTime
    /\ started \in BOOLEAN

\* =====================================================================
\* Helpers
\* =====================================================================

\* TRUE iff every sensor in room r except `excl` is inactive.
\* Mirrors ZoneState::all_other_sensors_inactive().
AllOtherInactive(excl, r) ==
    \A s2 \in Sensors[r] : s2 # excl => ~mact[s2]

\* TRUE iff the motion-on cooldown has elapsed for room r.
\* Uses IF-THEN-ELSE to guard arithmetic against NIL (model value).
CooldownPassed(r) ==
    IF Cooldown[r] = 0 THEN TRUE
    ELSE IF loa[r] = NIL THEN TRUE
    ELSE now - loa[r] >= Cooldown[r]

\* =====================================================================
\* Propagation helpers
\*
\* Build next-state function values that atomically update both the
\* target room and all its descendants, matching
\* propagate_to_descendants() in controller.rs.
\* =====================================================================

\* physically_on after ON event with propagation.
PonAfterOn(r) ==
    [r2 \in Rooms |-> IF r2 = r \/ r2 \in Descendants(r) THEN TRUE ELSE pon[r2]]

\* physically_on after OFF event with propagation.
PonAfterOff(r) ==
    [r2 \in Rooms |-> IF r2 = r \/ r2 \in Descendants(r) THEN FALSE ELSE pon[r2]]

\* motion_owned after propagation. The room itself gets `val`;
\* descendants always get FALSE (ancestor overrides child ownership).
MownAfterPropagate(r, val) ==
    [r2 \in Rooms |->
        CASE r2 = r -> val
          [] r2 \in Descendants(r) -> FALSE
          [] OTHER -> mown[r2]]

\* cycle_idx after propagation. Room gets `idx`; descendants reset to 0.
CidxAfterPropagate(r, idx) ==
    [r2 \in Rooms |->
        CASE r2 = r -> idx
          [] r2 \in Descendants(r) -> 0
          [] OTHER -> cidx[r2]]

\* last_press_at after propagation. Room gets `val`; descendants get NIL
\* (forces next press to take the expire branch).
LpaAfterPropagate(r, val) ==
    [r2 \in Rooms |->
        CASE r2 = r -> val
          [] r2 \in Descendants(r) -> NIL
          [] OTHER -> lpa[r2]]

\* last_off_at after OFF propagation. Room gets `val`;
\* descendants also get `val` for cooldown protection.
LoaAfterOffPropagate(r, val) ==
    [r2 \in Rooms |->
        CASE r2 = r -> val
          [] r2 \in Descendants(r) -> val
          [] OTHER -> loa[r2]]

\* =====================================================================
\* Initial state
\* =====================================================================

Init ==
    /\ pon    = [r \in Rooms |-> FALSE]
    /\ mown   = [r \in Rooms |-> FALSE]
    /\ cidx   = [r \in Rooms |-> 0]
    /\ lpa    = [r \in Rooms |-> NIL]
    /\ loa    = [r \in Rooms |-> NIL]
    /\ mact   = [s \in AllSensors |-> FALSE]
    /\ pOn    = [p \in Plugs |-> FALSE]
    /\ pidle  = [p \in Plugs |-> NIL]
    /\ now    = 0
    /\ started = FALSE

\* =====================================================================
\* Startup seeding (seed_motion_ownership_for_lit_rooms)
\*
\* Non-deterministically chooses which rooms are found physically on
\* at daemon startup, then marks them motion-owned.
\* =====================================================================

StartupSeed ==
    /\ ~started
    /\ \E litRooms \in SUBSET Rooms :
        /\ pon'  = [r \in Rooms |-> r \in litRooms]
        /\ mown' = [r \in Rooms |-> FALSE]  \* leave user-owned (trade-off)
        /\ UNCHANGED <<cidx, lpa, loa, mact>>
    /\ UNCHANGED plugVars
    /\ UNCHANGED now
    /\ started' = TRUE

\* =====================================================================
\* Motion sensor events
\* =====================================================================

\* --- Motion-on: sensor reports occupied, all gates pass ---
MotionOnFire(r, s, bright) ==
    /\ started
    /\ s \in Sensors[r]
    /\ ~pon[r]
    /\ ~(HasLuxGate[r] /\ bright)
    /\ CooldownPassed(r)
    /\ mact' = [mact EXCEPT ![s] = TRUE]
    /\ pon'  = PonAfterOn(r)
    /\ mown' = MownAfterPropagate(r, TRUE)
    /\ cidx' = CidxAfterPropagate(r, 0)
    /\ lpa'  = LpaAfterPropagate(r, lpa[r])    \* motion doesn't touch last_press_at
    /\ loa'  = loa                               \* ON doesn't touch last_off_at
    /\ UNCHANGED plugVars
    /\ UNCHANGED <<now, started>>

\* --- Motion-on: sensor reports occupied, at least one gate blocks ---
MotionOnBlock(r, s, bright) ==
    /\ started
    /\ s \in Sensors[r]
    /\ \/ pon[r]
       \/ (HasLuxGate[r] /\ bright)
       \/ ~CooldownPassed(r)
    /\ mact' = [mact EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<pon, mown, cidx, lpa, loa>>
    /\ UNCHANGED plugVars
    /\ UNCHANGED <<now, started>>

\* --- Motion-off: sensor reports unoccupied, all gates pass ---
MotionOffFire(r, s) ==
    /\ started
    /\ s \in Sensors[r]
    /\ mown[r]
    /\ pon[r]
    /\ AllOtherInactive(s, r)
    /\ mact' = [mact EXCEPT ![s] = FALSE]
    /\ pon'  = PonAfterOff(r)
    /\ mown' = MownAfterPropagate(r, FALSE)
    /\ cidx' = CidxAfterPropagate(r, 0)
    /\ lpa'  = LpaAfterPropagate(r, lpa[r])    \* motion doesn't touch last_press_at
    /\ loa'  = LoaAfterOffPropagate(r, now)
    /\ UNCHANGED plugVars
    /\ UNCHANGED <<now, started>>

\* --- Motion-off: sensor reports unoccupied, at least one gate blocks ---
MotionOffBlock(r, s) ==
    /\ started
    /\ s \in Sensors[r]
    /\ \/ ~mown[r]
       \/ ~pon[r]
       \/ ~AllOtherInactive(s, r)
    /\ mact' = [mact EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<pon, mown, cidx, lpa, loa>>
    /\ UNCHANGED plugVars
    /\ UNCHANGED <<now, started>>

\* =====================================================================
\* Wall switch events
\* =====================================================================

\* ON button: pure scene cycle, no time component, no off path.
\* Off -> fresh on (scene 0). On -> advance cycle mod N.
\* Matches wall_switch_on_press() in controller.rs.
WallSwitchOn(r) ==
    /\ started
    /\ RoomHasSwitch[r]
    /\ LET nextIdx == IF pon[r]
                       THEN (cidx[r] + 1) % NumScenes[r]
                       ELSE 0
       IN
        /\ pon'  = PonAfterOn(r)
        /\ mown' = MownAfterPropagate(r, FALSE)    \* user press clears ownership
        /\ cidx' = CidxAfterPropagate(r, nextIdx)
        /\ lpa'  = LpaAfterPropagate(r, now)
        /\ loa'  = loa                              \* ON doesn't set cooldown
    /\ UNCHANGED mact
    /\ UNCHANGED plugVars
    /\ UNCHANGED <<now, started>>

\* OFF button: always immediate off, regardless of current state.
\* Matches dispatch_switch(OffPressRelease) -> publish_off() -> write_after_off().
WallSwitchOff(r) ==
    /\ started
    /\ RoomHasSwitch[r]
    /\ pon'  = PonAfterOff(r)
    /\ mown' = MownAfterPropagate(r, FALSE)
    /\ cidx' = CidxAfterPropagate(r, 0)
    /\ lpa'  = LpaAfterPropagate(r, now)
    /\ loa'  = LoaAfterOffPropagate(r, now)
    /\ UNCHANGED mact
    /\ UNCHANGED plugVars
    /\ UNCHANGED <<now, started>>

\* =====================================================================
\* Tap button events
\*
\* Three-branch state machine (tap_press() in controller.rs):
\*   1. Off -> fresh on (first scene)
\*   2. On, within cycle window -> advance cycle
\*   3. On, outside cycle window -> expire to off
\* =====================================================================

TapFreshOn(r) ==
    /\ started
    /\ RoomHasTap[r]
    /\ ~pon[r]
    /\ pon'  = PonAfterOn(r)
    /\ mown' = MownAfterPropagate(r, FALSE)
    /\ cidx' = CidxAfterPropagate(r, 0)
    /\ lpa'  = LpaAfterPropagate(r, now)
    /\ loa'  = loa
    /\ UNCHANGED mact
    /\ UNCHANGED plugVars
    /\ UNCHANGED <<now, started>>

TapCycle(r) ==
    /\ started
    /\ RoomHasTap[r]
    /\ pon[r]
    /\ lpa[r] # NIL
    /\ (now - lpa[r]) < CycleWindow
    /\ LET nextIdx == (cidx[r] + 1) % NumScenes[r]
       IN
        /\ pon'  = PonAfterOn(r)
        /\ mown' = MownAfterPropagate(r, FALSE)
        /\ cidx' = CidxAfterPropagate(r, nextIdx)
        /\ lpa'  = LpaAfterPropagate(r, now)
        /\ loa'  = loa
    /\ UNCHANGED mact
    /\ UNCHANGED plugVars
    /\ UNCHANGED <<now, started>>

TapExpire(r) ==
    /\ started
    /\ RoomHasTap[r]
    /\ pon[r]
    /\ IF lpa[r] = NIL THEN TRUE
       ELSE (now - lpa[r]) >= CycleWindow
    /\ pon'  = PonAfterOff(r)
    /\ mown' = MownAfterPropagate(r, FALSE)
    /\ cidx' = CidxAfterPropagate(r, 0)
    /\ lpa'  = LpaAfterPropagate(r, now)
    /\ loa'  = LoaAfterOffPropagate(r, now)
    /\ UNCHANGED mact
    /\ UNCHANGED plugVars
    /\ UNCHANGED <<now, started>>

\* =====================================================================
\* Group state echo (external state changes via Hue app, HA, etc.)
\* Matches handle_group_state() in controller.rs.
\* =====================================================================

\* External OFF -> ON transition. Stays user-owned (trade-off:
\* room won't auto-off until a full motion cycle fires, but no
\* false auto-offs from stale sensor state).
GroupStateOn(r) ==
    /\ started
    /\ ~pon[r]
    /\ pon'  = [pon  EXCEPT ![r] = TRUE]
    /\ UNCHANGED <<mown, cidx, lpa, loa, mact>>
    /\ UNCHANGED plugVars
    /\ UNCHANGED <<now, started>>

\* External ON -> OFF transition. Clears ownership, resets cycle,
\* stamps last_off_at for cooldown protection.
GroupStateOff(r) ==
    /\ started
    /\ pon[r]
    /\ pon'  = [pon  EXCEPT ![r] = FALSE]
    /\ mown' = [mown EXCEPT ![r] = FALSE]
    /\ cidx' = [cidx EXCEPT ![r] = 0]
    /\ loa'  = [loa  EXCEPT ![r] = now]
    /\ UNCHANGED <<lpa, mact>>
    /\ UNCHANGED plugVars
    /\ UNCHANGED <<now, started>>

\* =====================================================================
\* Plug events
\* =====================================================================

\* Toggle plug on/off (from action rule dispatch).
PlugToggle(p) ==
    /\ started
    /\ pOn'   = [pOn   EXCEPT ![p] = ~pOn[p]]
    /\ pidle' = [pidle EXCEPT ![p] = NIL]
    /\ UNCHANGED roomVars
    /\ UNCHANGED <<now, started>>

\* Power drops below kill threshold -> start tracking idle time.
PlugPowerDrop(p) ==
    /\ started
    /\ pOn[p]
    /\ pidle[p] = NIL
    /\ pidle' = [pidle EXCEPT ![p] = now]
    /\ UNCHANGED pOn
    /\ UNCHANGED roomVars
    /\ UNCHANGED <<now, started>>

\* Power recovers above threshold -> clear idle tracking.
PlugPowerRecover(p) ==
    /\ started
    /\ pOn[p]
    /\ pidle[p] # NIL
    /\ pidle' = [pidle EXCEPT ![p] = NIL]
    /\ UNCHANGED pOn
    /\ UNCHANGED roomVars
    /\ UNCHANGED <<now, started>>

\* Kill switch fires: holdoff elapsed while idle.
KillSwitch(p) ==
    /\ started
    /\ pOn[p]
    /\ pidle[p] # NIL
    /\ now - pidle[p] >= KillHoldoff[p]
    /\ pOn'   = [pOn   EXCEPT ![p] = FALSE]
    /\ pidle' = [pidle EXCEPT ![p] = NIL]
    /\ UNCHANGED roomVars
    /\ UNCHANGED <<now, started>>

\* Plug turned off externally.
PlugExternalOff(p) ==
    /\ started
    /\ pOn[p]
    /\ pOn'   = [pOn   EXCEPT ![p] = FALSE]
    /\ pidle' = [pidle EXCEPT ![p] = NIL]
    /\ UNCHANGED roomVars
    /\ UNCHANGED <<now, started>>

\* =====================================================================
\* TurnOffAllZones effect
\*
\* Turns off every lit room. Iterates all rooms directly (no propagation).
\* Stamps last_off_at for cooldown protection.
\* =====================================================================

TurnOffAllZones ==
    /\ started
    /\ \E r \in Rooms : pon[r]          \* at least one room is on
    /\ pon'  = [r \in Rooms |-> FALSE]
    /\ mown' = [r \in Rooms |-> FALSE]
    /\ cidx' = [r \in Rooms |-> 0]
    /\ loa'  = [r \in Rooms |-> IF pon[r] THEN now ELSE loa[r]]
    /\ UNCHANGED <<lpa, mact>>
    /\ UNCHANGED plugVars
    /\ UNCHANGED <<now, started>>

\* =====================================================================
\* Time advancement
\* =====================================================================

Tick ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ UNCHANGED <<pon, mown, cidx, lpa, loa, mact, pOn, pidle, started>>

\* =====================================================================
\* Next-state relation
\* =====================================================================

Next ==
    \/ StartupSeed
    \/ \E r \in Rooms : \E s \in Sensors[r] : \E bright \in BOOLEAN :
        MotionOnFire(r, s, bright) \/ MotionOnBlock(r, s, bright)
    \/ \E r \in Rooms : \E s \in Sensors[r] :
        MotionOffFire(r, s) \/ MotionOffBlock(r, s)
    \/ \E r \in Rooms : WallSwitchOn(r)
    \/ \E r \in Rooms : WallSwitchOff(r)
    \/ \E r \in Rooms : TapFreshOn(r) \/ TapCycle(r) \/ TapExpire(r)
    \/ \E r \in Rooms : GroupStateOn(r) \/ GroupStateOff(r)
    \/ \E p \in Plugs :
        PlugToggle(p) \/ PlugPowerDrop(p) \/ PlugPowerRecover(p) \/
        KillSwitch(p) \/ PlugExternalOff(p)
    \/ TurnOffAllZones
    \/ Tick

\* Weak fairness on Tick so time always eventually advances.
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick)

\* =====================================================================
\* STATE INVARIANTS (must hold in every reachable state)
\* =====================================================================

\* S1: motion_owned implies physically_on. They clear atomically;
\*     no reachable state should have motion_owned=TRUE, physically_on=FALSE.
MotionOwnershipConsistent ==
    \A r \in Rooms : mown[r] => pon[r]

\* S2: cycle_idx is always within bounds.
CycleIdxValid ==
    \A r \in Rooms : cidx[r] < NumScenes[r]

\* S3: a plug's idle_since is only set when the plug is on.
PlugIdleOnlyWhenOn ==
    \A p \in Plugs : pidle[p] # NIL => pOn[p]

\* S4: No stuck state — if a room is off, has sensors, cooldown has
\*     passed (or is zero), and the environment offers a dark motion
\*     event, MotionOnFire is always ENABLED. No combination of
\*     internal state (mown, cidx, lpa, mact, plug state) can block it.
MotionAlwaysPossibleWhenOff ==
    \A r \in Rooms :
        (started /\ ~pon[r] /\ Sensors[r] # {} /\ CooldownPassed(r))
            => \E s \in Sensors[r] : ENABLED MotionOnFire(r, s, FALSE)

\* S5: When a room is off, cycle_idx is always 0. Every OFF transition
\*     resets the cycle; cidx only advances while pon=TRUE.
OffImpliesCycleReset ==
    \A r \in Rooms : ~pon[r] => cidx[r] = 0

\* S6: A room that is on but has no press history (lpa=NIL) must have
\*     cidx=0. Such rooms were turned on via motion, propagation, startup
\*     seed, or external event — none of which advance the cycle.
NilPressOnImpliesCycleZero ==
    \A r \in Rooms : (pon[r] /\ lpa[r] = NIL) => cidx[r] = 0

\* S7–S9: Timestamps are always in the past (or present). They are only
\*     ever set to `now`, and `now` monotonically increases.
LoaInPast ==
    \A r \in Rooms : loa[r] # NIL => loa[r] <= now

LpaInPast ==
    \A r \in Rooms : lpa[r] # NIL => lpa[r] <= now

PidleInPast ==
    \A p \in Plugs : pidle[p] # NIL => pidle[p] <= now

\* S10: Active cooldown actually blocks motion-on. Regression guard:
\*      if someone removes the cooldown check from MotionOnFire, this
\*      catches it.
CooldownBlocksMotion ==
    \A r \in Rooms :
        (started /\ ~pon[r] /\ Sensors[r] # {} /\ ~CooldownPassed(r))
            => \A s \in Sensors[r] : ~ENABLED MotionOnFire(r, s, FALSE)

\* S11: motion_owned requires at least one sensor to be actively
\*      reporting occupied. Startup seed and external ON leave rooms
\*      user-owned — only MotionOnFire sets motion_owned=TRUE, and it
\*      always records the sensor flag first.
\*      Trade-off: rooms that were on at restart or turned on externally
\*      won't auto-off via motion until the user manually toggles them.
MotionOwnedImpliesSensorHistory ==
    \A r \in Rooms :
        mown[r] => \E s \in Sensors[r] : mact[s]

\* =====================================================================
\* ACTION PROPERTIES (must hold across every state transition)
\*
\* Checked via [][P]_vars — the property P must hold for every
\* (state, state') pair in any behavior of the spec.
\* =====================================================================

\* A1: Every ON->OFF transition stamps last_off_at for cooldown protection.
OffAlwaysStampsLoa ==
    \A r \in Rooms :
        (pon[r] /\ ~pon'[r]) => (loa'[r] = now)

OffAlwaysStampsLoaProp == [][OffAlwaysStampsLoa]_vars

\* A2: Every ON->OFF transition resets the cycle index to 0.
OffAlwaysResetsCycle ==
    \A r \in Rooms :
        (pon[r] /\ ~pon'[r]) => cidx'[r] = 0

OffAlwaysResetsCycleProp == [][OffAlwaysResetsCycle]_vars

\* A3: Every ON->OFF transition clears motion_owned.
OffAlwaysClearsMotion ==
    \A r \in Rooms :
        (pon[r] /\ ~pon'[r]) => ~mown'[r]

OffAlwaysClearsMotionProp == [][OffAlwaysClearsMotion]_vars

\* A4: Every button press (detected by lpa changing) clears motion_owned.
\*     Covers: WallSwitchOn, WallSwitchOff, TapFreshOn, TapCycle, TapExpire,
\*     and descendant propagation (lpa reset to NIL also counts as a change).
UserPressClearsMotion ==
    \A r \in Rooms :
        (lpa'[r] # lpa[r]) => ~mown'[r]

UserPressClearsMotionProp == [][UserPressClearsMotion]_vars

\* A5: Every plug on/off state change clears idle tracking.
\*     Covers: PlugToggle (both directions), KillSwitch, PlugExternalOff.
PlugToggleClearsIdle ==
    \A p \in Plugs :
        (pOn'[p] # pOn[p]) => pidle'[p] = NIL

PlugToggleClearsIdleProp == [][PlugToggleClearsIdle]_vars

\* A6: ON transitions never touch the cooldown timestamp. Cooldown is
\*     only stamped by OFF transitions.
OnNeverStampsLoa ==
    \A r \in Rooms :
        (~pon[r] /\ pon'[r]) => loa'[r] = loa[r]

OnNeverStampsLoaProp == [][OnNeverStampsLoa]_vars

\* =====================================================================
\* LIVENESS PROPERTIES (require fairness, commented out for reference)
\* =====================================================================

\* L1: If motion-owned and all sensors inactive, room eventually turns off.
\*     Requires: WF on MotionOffFire for each (room, sensor) pair.
\* MotionEventuallyOff ==
\*     \A r \in Rooms :
\*         (mown[r] /\ \A s \in Sensors[r] : ~mact[s]) ~> ~pon[r]

\* L2: If a plug is idle past holdoff, it eventually turns off.
\*     Requires: WF on KillSwitch and Tick.
\* KillSwitchEventuallyFires ==
\*     \A p \in Plugs :
\*         (pOn[p] /\ pidle[p] # NIL /\ now - pidle[p] >= KillHoldoff[p])
\*             ~> ~pOn[p]

====
