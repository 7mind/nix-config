{ config, lib, pkgs, ... }:

{
  options = {
    smind.power-management.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable power management and CPU frequency scaling";
    };
  };

  config =
    (lib.mkIf config.smind.power-management.enable {
      boot = {
        # TODO: we need to verify if that's completely safe or not
        extraModprobeConfig = ''
          options snd_hda_intel power_save=1
        '';
      };
      powerManagement = {
        enable = true;
        # never enable powertop autotuning, it breaks usb inputs
        powertop.enable = false;
        scsiLinkPolicy = "med_power_with_dipm";
      };

      services.udev = {
        extraRules = ''
          ACTION=="add|change", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="on"
          ACTION=="add|change", SUBSYSTEM=="pci", TEST=="power/control", ATTR{power/control}="auto"
          ACTION=="add|change", SUBSYSTEM=="block", TEST=="power/control", ATTR{device/power/control}="auto"
          ACTION=="add|change", SUBSYSTEM=="ata_port", ATTR{../../power/control}="auto"
        '';
      };

      environment.systemPackages = with pkgs; [
        config.boot.kernelPackages.cpupower
      ];
    });
}
