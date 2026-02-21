{ config, lib, pkgs, ... }:

let
  steamSystemPackage = config.smind.gaming.steam.wrappedPackage;
  heroicSystemPackage = config.smind.gaming.steam.heroic.wrappedPackage;
in
{
  options = {
    smind.gaming.steam = {
      enable = lib.mkEnableOption "Steam with Proton-GE and Wayland support";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.steam.override {
          extraEnv = {
            SDL_VIDEO_DRIVER = "wayland";
            SDL_VIDEO_WAYLAND_SCALE_TO_DISPLAY = "1";
          };
        };
        description = "Steam package to install";
      };

      wrappedPackage = lib.mkOption {
        type = lib.types.package;
        default = config.smind.gaming.steam.package;
        description = "Wrapped Steam launcher package for system environment";
      };

      heroic.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Heroic Games Launcher (Epic/GOG)";
      };

      heroic.package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.heroic;
        description = "Heroic package to install";
      };

      heroic.wrappedPackage = lib.mkOption {
        type = lib.types.package;
        default = config.smind.gaming.steam.heroic.package;
        description = "Wrapped Heroic launcher package for system environment";
      };
    };
  };

  config = lib.mkIf config.smind.gaming.steam.enable {
    programs.steam = {
      enable = true;
      extraCompatPackages = [ pkgs.proton-ge-bin ];
      package = config.smind.gaming.steam.package;
    };

    environment.systemPackages =
      [ (lib.hiPrio steamSystemPackage) ]
      ++ (lib.optional config.smind.gaming.steam.heroic.enable
        (lib.hiPrio heroicSystemPackage));
  };
}
