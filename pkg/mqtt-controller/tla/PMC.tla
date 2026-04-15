---- MODULE PMC ----
\* Model configuration for TLC model checking of TassPlug.
\*
\* Models a single smart plug with kill switch automation, small power
\* range, and short holdoff. Designed for exhaustive state space exploration.

EXTENDS TassPlug

\* Model value for NIL sentinel.
CONSTANTS mc_NIL

\* ---- Constant definitions (override via <- in PMC.cfg) ----

MC_KillThreshold == 1
MC_KillHoldoff   == 2
MC_MaxPower      == 3
MC_MaxTime       == 6
MC_NIL           == mc_NIL

====
