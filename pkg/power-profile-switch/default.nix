{ pkgs, lib, profileOnAC ? "performance", profileOnBattery ? "power-saver" }:

let
  setProfile = pkgs.writeShellScript "power-profile-set" ''
    exec ${./power-profile-set.sh} \
      "${profileOnAC}" \
      "${profileOnBattery}" \
      "${pkgs.power-profiles-daemon}/bin/powerprofilesctl"
  '';
in
{
  inherit setProfile;
}
