{ pkgs, lib, gnomeDisplayConfigLines ? "", cosmicDisplayConfigLines ? "" }:

let
  scriptDir = ./.;

  cosmicSetRefreshRate = pkgs.writeShellScript "refresh-rate-set-cosmic" ''
    exec ${scriptDir}/refresh-rate-set-cosmic.sh \
      "${cosmicDisplayConfigLines}" \
      "${pkgs.wlr-randr}/bin/wlr-randr"
  '';

  gnomeSetRefreshRate = pkgs.writeShellScript "refresh-rate-set-gnome" ''
    exec ${scriptDir}/refresh-rate-set-gnome.sh \
      "${gnomeDisplayConfigLines}" \
      "${pkgs.mutter}/bin/gdctl"
  '';

  triggerRefreshRateUpdate = pkgs.writeShellScript "trigger-refresh-rate-update" ''
    exec ${scriptDir}/trigger-refresh-rate-update.sh \
      "${pkgs.systemd}/bin/loginctl"
  '';
in
{
  inherit cosmicSetRefreshRate gnomeSetRefreshRate triggerRefreshRateUpdate;
}
