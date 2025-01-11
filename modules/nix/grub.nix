{ config, lib, ... }:

{
  options = {
    smind.grub.efi.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.grub.efi.enable {
    assertions = [ ];
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
