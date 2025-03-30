{ config, lib, pkgs, ... }:

{
  options = {
    smind.hw.oracle-cloud.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hw.oracle-cloud.enable {
    boot.kernelParams = [
      "console=ttyS0"
      "console=tty1"
      "nvme.shutdown_timeout=10"
      "libiscsi.debug_libiscsi_eh=1"
    ];

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    smind = {
      hw.cpu.isArm = true;
      systemd-boot.enable = true;
      isDesktop = false;
      roles.desktop.generic-gnome = false;

    };
  };
}
