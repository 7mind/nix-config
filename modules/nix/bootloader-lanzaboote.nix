{ config, lib, ... }:

{
  options = {
    smind.lanzaboote.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.lanzaboote.enable {
    boot.loader = {
      grub.enable = lib.mkForce false;

      efi.efiSysMountPoint = "/boot";

      timeout = 2;

      systemd-boot = {
        enable = lib.mkForce false;
        memtest86.enable = lib.mkForce false;
        edk2-uefi-shell.enable = lib.mkForce false;
      };
    };

    boot.lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
      settings = {
        consoleMode = "keep";
        configurationLimit = 3;
        reboot-for-bitlocker = true;
      };
    };
  };
}
