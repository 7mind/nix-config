{ pkgs, lib, gnomeDisplayConfigLines ? "", cosmicDisplayConfigLines ? "" }:

let
  isOnAcScript = builtins.readFile ./is-on-ac.sh;

  cosmicSetRefreshRate = pkgs.writeShellScript "refresh-rate-set-cosmic" ''
    ${isOnAcScript}
    ${builtins.readFile ./refresh-rate-set-cosmic.sh}

    main "${cosmicDisplayConfigLines}" "${pkgs.wlr-randr}/bin/wlr-randr"
  '';

  gnomeSetRefreshRate = pkgs.writeShellScript "refresh-rate-set-gnome" ''
    ${isOnAcScript}
    ${builtins.readFile ./refresh-rate-set-gnome.sh}

    main "${gnomeDisplayConfigLines}" "${pkgs.mutter}/bin/gdctl"
  '';

  triggerRefreshRateUpdate = pkgs.writeShellScript "trigger-refresh-rate-update" ''
    ${builtins.readFile ./trigger-refresh-rate-update.sh}

    main "${pkgs.systemd}/bin/loginctl"
  '';
in
{
  inherit cosmicSetRefreshRate gnomeSetRefreshRate triggerRefreshRateUpdate;
}
