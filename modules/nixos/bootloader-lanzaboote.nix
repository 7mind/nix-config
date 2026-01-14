{ config, lib, ... }:

{
  options = {
    smind.bootloader.lanzaboote.enable = lib.mkEnableOption "Lanzaboote for Secure Boot support";
  };

  config = lib.mkIf config.smind.bootloader.lanzaboote.enable {
    boot.loader = {
      grub.enable = lib.mkForce false;

      efi.efiSysMountPoint = "/boot";

      timeout = 2;

      systemd-boot = {
        enable = lib.mkForce false;
        configurationLimit = 3;
        memtest86.enable = true;
        edk2-uefi-shell.enable = true;
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
