{ config, lib, pkgs, ... }:

{
  options = {
    smind.power-management.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.power-management.enable {
    assertions = [ ];
    boot = {
      # TODO: we need to verify if that's completely safe or not
      extraModprobeConfig = ''
        options snd_hda_intel power_save=1
      '';
    };
    powerManagement = {
      enable = true;
      scsiLinkPolicy = "med_power_with_dipm";
    };

    services.udev = {
      extraRules = ''
        ACTION=="add|change", SUBSYSTEM=="pci", ATTR{power/control}="auto"
        ACTION=="add|change", SUBSYSTEM=="block", ATTR{device/power/control}="auto"
        ACTION=="add|change", SUBSYSTEM=="ata_port", ATTR{../../power/control}="auto"
      '';
    };
  };
}
