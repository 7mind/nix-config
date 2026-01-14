{ config, lib, pkgs, ... }:

{
  options = {
    smind.hw.oracle-cloud.enable = lib.mkEnableOption "Oracle Cloud instance optimizations";
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
  };
}
