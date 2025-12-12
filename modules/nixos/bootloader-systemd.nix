{ config, lib, pkgs, cfg-meta, ... }:

{
  options = {
    smind.bootloader.systemd-boot.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use systemd-boot as EFI bootloader";
    };
  };

  config = lib.mkIf config.smind.bootloader.systemd-boot.enable {
    boot.loader = {
      grub.enable = lib.mkForce false;
      efi.efiSysMountPoint = "/boot";
      timeout = 2;
      systemd-boot = {
        enable = true;
        memtest86.enable = pkgs.lib.hasPrefix "x86_64" cfg-meta.arch;
        edk2-uefi-shell.enable = true;
        consoleMode = "max";
        configurationLimit = 3;
      };
    };
  };
}
