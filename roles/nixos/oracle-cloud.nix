{ config, lib, ... }:

{
  options = {
    smind.roles.server.oracle-cloud = lib.mkEnableOption "Oracle Cloud ARM server role";
  };

  config = lib.mkIf config.smind.roles.server.oracle-cloud {
    smind = {
      roles.server.generic = true;

      environment.linux.fwupd.enable = false;
      hw.cpu.isArm = true;
      hw.fwupd.enable = false;
      hw.oracle-cloud.enable = true;

      bootloader.systemd-boot.enable = true;

      # Off-LAN: the attic server on the home network is unreachable from
      # Oracle Cloud, so don't list it as a substituter. The cache's signing
      # key is still trusted (infra.attic-cache.enable defaults to true) so
      # SSH-pushed paths from other hosts are accepted.
      infra.attic-cache.substituter.enable = lib.mkDefault false;
    };
  };
}
