{ config, lib, ... }:

{
  options = {
    smind.roles.server.oracle-cloud = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.roles.server.oracle-cloud {
    smind = {
      hw.cpu.isArm = true;
      hw.oracle-cloud.enable = true;

      systemd-boot.enable = true;
      isDesktop = false;
      roles.desktop.generic-gnome = false;
    };
  };
}
