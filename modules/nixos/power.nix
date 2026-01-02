{ config, lib, pkgs, ... }:

let
  cfg = config.smind.power-management;
in
{
  options.smind.power-management = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable power management and CPU frequency scaling";
    };

    auto-profile = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Automatically switch power profiles based on AC/battery status";
      };

      onAC = lib.mkOption {
        type = lib.types.enum [ "power-saver" "balanced" "performance" ];
        default = "balanced";
        description = "Power profile to use when on AC power";
      };

      onBattery = lib.mkOption {
        type = lib.types.enum [ "power-saver" "balanced" "performance" ];
        default = "power-saver";
        description = "Power profile to use when on battery";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
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
    })

    # Auto-switch power profiles based on AC/battery status
    (lib.mkIf cfg.auto-profile.enable {
      assertions = [{
        assertion = config.services.power-profiles-daemon.enable;
        message = "auto-profile requires services.power-profiles-daemon.enable = true";
      }];

      services.udev.extraRules = ''
        # Switch to ${cfg.auto-profile.onAC} when AC is connected
        ACTION=="change", SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="1", RUN+="${pkgs.power-profiles-daemon}/bin/powerprofilesctl set ${cfg.auto-profile.onAC}"
        # Switch to ${cfg.auto-profile.onBattery} when on battery
        ACTION=="change", SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="0", RUN+="${pkgs.power-profiles-daemon}/bin/powerprofilesctl set ${cfg.auto-profile.onBattery}"
      '';
    })
  ];
}
