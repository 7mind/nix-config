{ config, lib, ... }:

{
  options = {
    smind.roles.server.oracle-cloud = lib.mkEnableOption "Oracle Cloud ARM server role";
  };

  config = lib.mkIf config.smind.roles.server.oracle-cloud {
    smind = {
      roles.server.generic = true;

      hw.cpu.isArm = true;
      hw.oracle-cloud.enable = true;

      bootloader.systemd-boot.enable = true;
    };
  };
}
