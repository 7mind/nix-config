---- MODULE Heating ----
\* TLA+ formal specification of the heating controller state machine.
\*
\* Independent from the lighting/plug model (HueController.tla).
\* The two subsystems share no state and have no cross-system invariants,
\* so they are verified separately to keep the state space tractable.
\*
\* Models:
\*   - TRV heat demand (environment non-determinism)
\*   - Zone relay control (controller logic)
\*   - Global heat pump short-cycling protection (min cycle, min pause)
\*   - Pressure group enforcement (force-open / release)
\*
\* Open window detection is abstracted: it only affects whether a TRV's
\* demand is visible to the relay controller, which the environment
\* already controls non-deterministically via HeatDemandOn/Off.

EXTENDS Integers, FiniteSets

\* =====================================================================
\* Constants
\* =====================================================================

CONSTANTS
    HZones,             \* Set of heating zone identifiers
    TRVs,               \* Set of TRV identifiers
    TrvZone,            \* [TRVs -> HZones] which zone each TRV belongs to
    PressureGroups,     \* SUBSET (SUBSET TRVs): set of TRV-sets
    MinCycle,           \* Nat: minimum pump run time (time units)
    MinPause,           \* Nat: minimum pump pause time (time units)
    MaxTime,            \* Nat: upper bound for bounded model checking
    NIL                 \* Sentinel: "no value"

\* =====================================================================
\* Variables
\* =====================================================================

VARIABLES
    relayOn,    \* [HZones -> BOOLEAN]          zone relay on/off
    relayAt,    \* [HZones -> Nat \cup {NIL}]   when relay turned on
    pumpOn,     \* Nat \cup {NIL}               pump on since (first relay)
    pumpOff,    \* Nat \cup {NIL}               pump off since (last relay)
    demand,     \* [TRVs -> BOOLEAN]            TRV heat demand
    forced,     \* [TRVs -> BOOLEAN]            TRV pressure-forced open
    now         \* Nat                          monotonic clock

vars == <<relayOn, relayAt, pumpOn, pumpOff, demand, forced, now>>
relayVars == <<relayOn, relayAt, pumpOn, pumpOff>>

\* =====================================================================
\* Derived operators (must come after VARIABLES)
\* =====================================================================

\* TRVs belonging to a specific zone.
TRVsInZone(z) == {t \in TRVs : TrvZone[t] = z}

\* TRUE iff any zone has its relay on (pump is running).
AnyRelayOn == \E z \in HZones : relayOn[z]

\* Count of zones with relay on.
ActiveRelayCount == Cardinality({z \in HZones : relayOn[z]})

\* TRUE iff zone z has effective demand (any TRV demanding).
ZoneHasDemand(z) == \E t \in TRVsInZone(z) : demand[t]

\* =====================================================================
\* Type invariant
\* =====================================================================

TypeOK ==
    /\ relayOn \in [HZones -> BOOLEAN]
    /\ \A z \in HZones : relayAt[z] \in (0..MaxTime) \cup {NIL}
    /\ pumpOn  \in (0..MaxTime) \cup {NIL}
    /\ pumpOff \in (0..MaxTime) \cup {NIL}
    /\ demand  \in [TRVs -> BOOLEAN]
    /\ forced  \in [TRVs -> BOOLEAN]
    /\ now     \in 0..MaxTime

\* =====================================================================
\* Initial state
\* =====================================================================

Init ==
    /\ relayOn = [z \in HZones |-> FALSE]
    /\ relayAt = [z \in HZones |-> NIL]
    /\ pumpOn  = NIL
    /\ pumpOff = NIL
    /\ demand  = [t \in TRVs |-> FALSE]
    /\ forced  = [t \in TRVs |-> FALSE]
    /\ now     = 0

\* =====================================================================
\* Environment: TRV demand changes
\* =====================================================================

\* TRV starts demanding heat.
DemandOn(t) ==
    /\ ~demand[t]
    /\ demand' = [demand EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<relayOn, relayAt, pumpOn, pumpOff, forced, now>>

\* TRV stops demanding heat.
DemandOff(t) ==
    /\ demand[t]
    /\ demand' = [demand EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<relayOn, relayAt, pumpOn, pumpOff, forced, now>>

\* =====================================================================
\* Controller: relay ON
\*
\* Turn zone relay ON when zone has demand and short-cycling allows it.
\* Two sub-cases: pump already running (no pause check), or pump
\* starting (min_pause must have elapsed).
\* =====================================================================

RelayOn(z) ==
    /\ ~relayOn[z]
    /\ ZoneHasDemand(z)
    \* Short-cycling: if pump is off, min_pause must have elapsed.
    /\ IF AnyRelayOn
       THEN TRUE
       ELSE IF pumpOff = NIL THEN TRUE
            ELSE now - pumpOff >= MinPause
    /\ relayOn' = [relayOn EXCEPT ![z] = TRUE]
    /\ relayAt' = [relayAt EXCEPT ![z] = now]
    \* If this is the first relay, record pump start.
    /\ IF ~AnyRelayOn
       THEN /\ pumpOn'  = now
            /\ pumpOff' = NIL
       ELSE UNCHANGED <<pumpOn, pumpOff>>
    /\ UNCHANGED <<demand, forced, now>>

\* =====================================================================
\* Controller: relay OFF
\*
\* Turn zone relay OFF when zone has no demand and short-cycling allows.
\* If this is the last relay (pump would stop), min_cycle must have elapsed.
\* =====================================================================

RelayOff(z) ==
    /\ relayOn[z]
    /\ ~ZoneHasDemand(z)
    \* If this is the last relay, check min_cycle.
    /\ IF ActiveRelayCount = 1
       THEN IF pumpOn = NIL THEN TRUE
            ELSE now - pumpOn >= MinCycle
       ELSE TRUE
    /\ relayOn' = [relayOn EXCEPT ![z] = FALSE]
    /\ relayAt' = [relayAt EXCEPT ![z] = NIL]
    \* If this is the last relay, record pump stop.
    /\ IF ActiveRelayCount = 1
       THEN /\ pumpOff' = now
            /\ pumpOn'  = NIL
       ELSE UNCHANGED <<pumpOn, pumpOff>>
    /\ UNCHANGED <<demand, forced, now>>

\* =====================================================================
\* Controller: pressure group enforcement
\* =====================================================================

\* Force-open non-demanding TRVs in a group with at least one demanding member.
PressureForce(g) ==
    /\ g \in PressureGroups
    /\ \E t \in g : demand[t]                       \* at least one demands
    /\ \E t \in g : ~forced[t] /\ ~demand[t]        \* at least one to force
    /\ forced' = [t \in TRVs |->
        IF t \in g /\ ~demand[t] THEN TRUE ELSE forced[t]]
    /\ UNCHANGED <<relayOn, relayAt, pumpOn, pumpOff, demand, now>>

\* Release forced TRVs when no member of the group has demand.
PressureRelease(g) ==
    /\ g \in PressureGroups
    /\ \A t \in g : ~demand[t]                       \* no demand in group
    /\ \E t \in g : forced[t]                         \* at least one forced
    /\ forced' = [t \in TRVs |->
        IF t \in g THEN FALSE ELSE forced[t]]
    /\ UNCHANGED <<relayOn, relayAt, pumpOn, pumpOff, demand, now>>

\* =====================================================================
\* Time advancement
\* =====================================================================

Tick ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ UNCHANGED <<relayOn, relayAt, pumpOn, pumpOff, demand, forced>>

\* =====================================================================
\* Next-state relation
\* =====================================================================

Next ==
    \/ \E t \in TRVs : DemandOn(t) \/ DemandOff(t)
    \/ \E z \in HZones : RelayOn(z) \/ RelayOff(z)
    \/ \E g \in PressureGroups : PressureForce(g) \/ PressureRelease(g)
    \/ Tick

Spec == Init /\ [][Next]_vars /\ WF_vars(Tick)

\* =====================================================================
\* STATE INVARIANTS
\* =====================================================================

\* H1: pumpOn is set iff any relay is on.
PumpOnConsistent ==
    (pumpOn # NIL) <=> AnyRelayOn

\* H2: relayAt is set iff the relay is on.
RelayAtConsistent ==
    \A z \in HZones : (relayAt[z] # NIL) <=> relayOn[z]

\* H3: pumpOn and pumpOff are mutually exclusive.
PumpMutuallyExclusive ==
    ~(pumpOn # NIL /\ pumpOff # NIL)

\* H4: timestamps are in the past.
PumpOnInPast ==
    pumpOn # NIL => pumpOn <= now

PumpOffInPast ==
    pumpOff # NIL => pumpOff <= now

RelayAtInPast ==
    \A z \in HZones : relayAt[z] # NIL => relayAt[z] <= now

\* H5: a forced TRV is always a member of some pressure group.
ForcedImpliesGroupMember ==
    \A t \in TRVs :
        forced[t] => \E g \in PressureGroups : t \in g

\* =====================================================================
\* ACTION PROPERTIES
\* =====================================================================

\* HA1: Relay ON when pump was off → min_pause elapsed.
MinPauseRespected ==
    \A z \in HZones :
        (~relayOn[z] /\ relayOn'[z] /\ ~AnyRelayOn)
            => (pumpOff = NIL \/ now - pumpOff >= MinPause)

MinPauseRespectedProp == [][MinPauseRespected]_vars

\* HA2: Last relay OFF → min_cycle elapsed since pump started.
MinCycleRespected ==
    \A z \in HZones :
        (relayOn[z] /\ ~relayOn'[z] /\ ActiveRelayCount = 1)
            => (pumpOn = NIL \/ now - pumpOn >= MinCycle)

MinCycleRespectedProp == [][MinCycleRespected]_vars

\* HA3: Relay ON always sets relayAt to now.
RelayOnStampsTime ==
    \A z \in HZones :
        (~relayOn[z] /\ relayOn'[z]) => relayAt'[z] = now

RelayOnStampsTimeProp == [][RelayOnStampsTime]_vars

\* HA4: Relay OFF always clears relayAt.
RelayOffClearsTime ==
    \A z \in HZones :
        (relayOn[z] /\ ~relayOn'[z]) => relayAt'[z] = NIL

RelayOffClearsTimeProp == [][RelayOffClearsTime]_vars

====
