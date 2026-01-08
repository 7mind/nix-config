{ pkgs, lib, profileOnAC ? "performance", profileOnBattery ? "power-saver" }:

let
  setProfile = pkgs.writeShellScript "power-profile-set" (builtins.readFile ./power-profile-set.sh + ''

    # Call with configured arguments
    main "${profileOnAC}" "${profileOnBattery}" "${pkgs.power-profiles-daemon}/bin/powerprofilesctl"
  '');
in
{
  inherit setProfile;
}
