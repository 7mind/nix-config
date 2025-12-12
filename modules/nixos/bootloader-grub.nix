{ config, lib, ... }:

{
  options = {
    smind.bootloader.grub.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use GRUB as EFI bootloader with OS prober";
    };
  };

  config = lib.mkIf config.smind.bootloader.grub.enable {
    boot.loader.efi = {
      canTouchEfiVariables = false;
    };

    boot.loader.grub = {
      enable = true;
      useOSProber = true;
      memtest86.enable = true;

      device = "nodev";
      efiSupport = true;
      efiInstallAsRemovable = true;
      extraEntries = ''
        menuentry "Firmware setup" {
            fwsetup
        }
      '';
    };
  };
}
