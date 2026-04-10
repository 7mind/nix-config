---- MODULE MC ----
\* Model configuration for TLC model checking of HueController.
\*
\* Topology:
\*   r_parent  — has 1 sensor (s1), 1 tap button, no wall switch
\*   r_child   — has 2 sensors (s2, s3), 1 wall switch, no tap,
\*               parent = r_parent, cooldown = 2, illuminance gate
\*   p1        — one smart plug with kill-switch holdoff = 3

EXTENDS HueController, TLC

\* Model values (uninterpreted constants for TLC).
CONSTANTS mc_r_parent, mc_r_child,
          mc_s1, mc_s2, mc_s3,
          mc_p1,
          mc_NIL

\* ---- Constant definitions (override via <- in MC.cfg) ----

MC_Rooms        == {mc_r_parent, mc_r_child}
MC_Sensors      == (mc_r_parent :> {mc_s1} @@ mc_r_child :> {mc_s2, mc_s3})
MC_NumScenes    == (mc_r_parent :> 2 @@ mc_r_child :> 3)
MC_Parent       == (mc_r_parent :> mc_NIL @@ mc_r_child :> mc_r_parent)
MC_Cooldown     == (mc_r_parent :> 0 @@ mc_r_child :> 2)
MC_HasLuxGate   == (mc_r_parent :> FALSE @@ mc_r_child :> TRUE)
MC_CycleWindow  == 1
MC_RoomHasSwitch == (mc_r_parent :> FALSE @@ mc_r_child :> TRUE)
MC_RoomHasTap   == (mc_r_parent :> TRUE @@ mc_r_child :> FALSE)
MC_Plugs        == {mc_p1}
MC_KillHoldoff  == (mc_p1 :> 3)
MC_MaxTime      == 5
MC_NIL          == mc_NIL

====
