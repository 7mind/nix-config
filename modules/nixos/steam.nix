{ config, lib, pkgs, ... }:

{
  options = {
    smind.gaming.steam = {
      enable = lib.mkEnableOption "Steam with Proton-GE and Wayland support";

      heroic.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Heroic Games Launcher (Epic/GOG)";
      };
    };
  };

  config = lib.mkIf config.smind.gaming.steam.enable {
    programs.steam = {
      enable = true;
      extraCompatPackages = [ pkgs.proton-ge-bin ];
      package = pkgs.steam.override {
        extraEnv = {
          SDL_VIDEO_DRIVER = "wayland";
          SDL_VIDEO_WAYLAND_SCALE_TO_DISPLAY = "1";
        };
      };
    };

    environment.systemPackages = lib.mkIf config.smind.gaming.steam.heroic.enable [
      pkgs.heroic
    ];
  };
}
