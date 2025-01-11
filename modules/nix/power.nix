{ config, lib, pkgs, ... }:

{
  options = {
    smind.power-management.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
    smind.power-management.desktop.amd.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.power-management.enable && config.smind.hw.cpu.isAmd;
      description = "";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf config.smind.power-management.enable {
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

      environment.systemPackages = with pkgs; [
        config.boot.kernelPackages.cpupower
      ];
    })

    (lib.mkIf config.smind.power-management.desktop.amd.enable {
      boot = {
        kernelParams = [
          # "msr.allow_writes=on"
        ];
      };
      powerManagement = {
        cpuFreqGovernor = "performance";
      };

      services.cpupower-gui.enable = true;

      services.auto-epp = {
        enable = true;
        settings = {
          Settings.epp_state_for_BAT = "power";
          Settings.epp_state_for_AC = "balance_performance";
        };
      };


      environment.systemPackages = with pkgs; [
        cpupower-gui
      ];
    })
  ];
}
