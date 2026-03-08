{ config, pkgs, lib, ... }:

let
  cfg = config.smind.hm.megasync;

  megasyncOverrides = drv: {
    buildInputs = drv.buildInputs ++ [ pkgs.makeWrapper ];
    preFixup = ''
      ${drv.preFixup}
      ${lib.optionalString cfg.gnomeTheme.enable ''qtWrapperArgs+=(--set "QT_STYLE_OVERRIDE" "adwaita")''}
      qtWrapperArgs+=(--set "DO_NOT_UNSET_XDG_SESSION_TYPE" "1")
    '';
  };
in
{
  options.smind.hm.megasync = {
    enable = lib.mkEnableOption "MEGAsync cloud storage client";
    gnomeTheme.enable = lib.mkEnableOption "Adwaita/GNOME theme override for MEGAsync";
  };

  config = lib.mkIf cfg.enable {
    services.megasync = {
      enable = true;
      forceWayland = true;
      package = pkgs.megasync.overrideAttrs megasyncOverrides;
    };
  };
}
