{ config, lib, ... }:

{
  options = {
    smind.systemd-boot.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.systemd-boot.enable {
    boot.loader = {
      grub.enable = lib.mkForce false;
      efi.efiSysMountPoint = "/boot";
      timeout = 2;
      systemd-boot = {
        enable = true;
        memtest86.enable = true;
        edk2-uefi-shell.enable = true;
        consoleMode = "max";
        configurationLimit = 3;
      };
    };
  };
}
