{ pkgs, lib, profileOnAC ? "performance", profileOnBattery ? "power-saver", minWatts ? null }:

let
  # Empty string => legacy "any Mains online" behavior; a number => USB-PD
  # unconstrained-charger + wattage-floor policy.
  minWattsArg = if minWatts == null then "" else toString minWatts;
  setProfile = pkgs.writeShellScript "power-profile-set" (
    builtins.readFile ../charger-detect/charger-detect.sh
    + builtins.readFile ./power-profile-set.sh + ''

    # Call with configured arguments
    main "${profileOnAC}" "${profileOnBattery}" "${pkgs.power-profiles-daemon}/bin/powerprofilesctl" "${minWattsArg}"
  '');
in
{
  inherit setProfile;
}
