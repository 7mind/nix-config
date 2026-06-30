{ pkgs, lib, gnomeDisplayConfigLines ? "", cosmicDisplayConfigLines ? "", minWatts ? null }:

let
  # Empty string => legacy "any Mains online"; a number => USB-PD
  # unconstrained-charger + wattage-floor policy (shared with power-profiles).
  minWattsArg = if minWatts == null then "" else toString minWatts;
  chargerDetect = builtins.readFile ../charger-detect/charger-detect.sh;
  isOnAcScript = builtins.readFile ./is-on-ac.sh;

  # Common preamble: configure the wattage threshold, load shared charger
  # detection, then is_on_ac (which delegates to it).
  preamble = ''
    REFRESH_AC_MIN_WATTS="${minWattsArg}"
    ${chargerDetect}
    ${isOnAcScript}
  '';

  cosmicSetRefreshRate = pkgs.writeShellScript "refresh-rate-set-cosmic" ''
    ${preamble}
    ${builtins.readFile ./refresh-rate-set-cosmic.sh}

    main "${cosmicDisplayConfigLines}" "${pkgs.wlr-randr}/bin/wlr-randr"
  '';

  gnomeSetRefreshRate = pkgs.writeShellScript "refresh-rate-set-gnome" ''
    ${preamble}
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
