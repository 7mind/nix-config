---- MODULE MC ----
\* Model configuration for TLC model checking of TassLightZone.
\*
\* Models a single light zone with motion sensor, small time bounds,
\* and a short cooldown. Designed for exhaustive state space exploration.

EXTENDS TassLightZone

\* Model value for NIL sentinel.
CONSTANTS mc_NIL

\* ---- Constant definitions (override via <- in MC.cfg) ----

MC_CycleWindow  == 2
MC_Cooldown     == 2
MC_HasMotion    == TRUE
MC_MaxTime      == 5
MC_NIL          == mc_NIL

====
