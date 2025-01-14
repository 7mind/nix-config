{ config, lib, pkgs, ... }:

{
  options = {
    smind.hm.environment.sane-defaults.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "";
    };

    smind.hm.environment.all-docs.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.environment.sane-defaults.enable {
    manual = lib.mkIf config.smind.hm.environment.all-docs.enable {
      html.enable = true;
    };

    home.packages = with pkgs; [
      libreoffice-fresh

      imagemagick
      vlc
      mpv
    ];

    programs.chromium.enable = true;
    programs.librewolf.enable = true;
    services.megasync.enable = true;
  };
}
