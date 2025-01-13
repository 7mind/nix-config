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
      roles.server = true;

      firefox.enable = true;
      firefox.no-tabbar = true;
      dev.generic.enable = true;
      dev.scala.enable = true;
      kitty.enable = true;
      vscodium.enable = true;
      wezterm.enable = true;
    };
  };
}
