{ config, lib, ... }:

{
  options = {
    smind.hm.roles.desktop = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.roles.desktop {
    smind.hm = {
      roles.server = lib.mkDefault true;

      firefox.enable = lib.mkDefault true;
      firefox.no-tabbar = lib.mkDefault true;
      dev.generic.enable = lib.mkDefault true;
      dev.cs.enable = lib.mkDefault true;
      dev.git.enable = lib.mkDefault true;
      dev.scala.enable = lib.mkDefault true;
      kitty.enable = lib.mkDefault true;
      vscodium.enable = lib.mkDefault true;
      zed.enable = lib.mkDefault true;
      wezterm.enable = lib.mkDefault true;
      autostart.programs = [ ];
      cleanups.enable = lib.mkDefault true;
      environment.sane-defaults.enable = lib.mkDefault true;
    };
  };
}
