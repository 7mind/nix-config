---- MODULE HMC ----
\* Model configuration for TLC model checking of Heating.
\*
\* Heating topology:
\*   hz1 — zone with 1 TRV (ht1), no pressure group
\*   hz2 — zone with 2 TRVs (ht2, ht3) in a pressure group
\*   MinCycle = 2, MinPause = 2, MaxTime = 6

EXTENDS Heating, TLC

\* Model values (uninterpreted constants for TLC).
CONSTANTS mc_hz1, mc_hz2,
          mc_ht1, mc_ht2, mc_ht3,
          mc_NIL

\* ---- Constant definitions ----

MC_HZones          == {mc_hz1, mc_hz2}
MC_TRVs            == {mc_ht1, mc_ht2, mc_ht3}
MC_TrvZone         == (mc_ht1 :> mc_hz1 @@ mc_ht2 :> mc_hz2 @@ mc_ht3 :> mc_hz2)
MC_PressureGroups  == {{mc_ht2, mc_ht3}}
MC_MinCycle        == 2
MC_MinPause        == 2
MC_MaxTime         == 6
MC_NIL             == mc_NIL

====
