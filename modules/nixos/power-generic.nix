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

    amd.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable && config.smind.hw.cpu.isAmd;
      description = "Enable AMD-specific power management (amd_pstate, auto-epp)";
    };

    suspend.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.isLaptop;
      description = "Enable suspend support";
    };

    hibernate.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.isLaptop && !config.smind.zfs.enable;
      description = "Enable hibernate and hybrid-sleep support (disabled by default with ZFS)";
    };

    powerButton = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [
        "ignore" "poweroff" "reboot" "halt" "kexec"
        "suspend" "hibernate" "hybrid-sleep" "suspend-then-hibernate" "lock"
      ]);
      default =
        if config.smind.isLaptop then
          (if cfg.hibernate.enable then "hybrid-sleep" else "suspend")
        else
          "poweroff";
      description = "Power button action (null to use system default)";
    };
  };

  config = lib.mkMerge [
    # Base power management
    (lib.mkIf cfg.enable {
      boot.extraModprobeConfig = ''
        options snd_hda_intel power_save=1
      '';

      powerManagement = {
        enable = true;
        powertop.enable = false; # breaks USB inputs
        scsiLinkPolicy = "med_power_with_dipm";
      };

      services.udev.extraRules = ''
        ACTION=="add|change", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="on"
        ACTION=="add|change", SUBSYSTEM=="pci", TEST=="power/control", ATTR{power/control}="auto"
        ACTION=="add|change", SUBSYSTEM=="block", TEST=="power/control", ATTR{device/power/control}="auto"
        ACTION=="add|change", SUBSYSTEM=="ata_port", ATTR{../../power/control}="auto"
      '';

      environment.systemPackages = [
        config.boot.kernelPackages.cpupower
      ];
    })

    # AMD-specific power management
    (lib.mkIf cfg.amd.enable {
      powerManagement.cpuFreqGovernor = "powersave"; # amd-pstate uses powersave governor

      services.cpupower-gui.enable = true;

      environment.systemPackages = [ pkgs.cpupower-gui ];
    })

    # Suspend/hibernate systemd targets
    (lib.mkIf (cfg.suspend.enable || cfg.hibernate.enable) {
      systemd.targets.sleep.enable = true;
    })
    (lib.mkIf cfg.suspend.enable {
      systemd.targets.suspend.enable = true;
    })
    (lib.mkIf cfg.hibernate.enable {
      systemd.targets.hibernate.enable = true;
      systemd.targets.hybrid-sleep.enable = true;
    })

    # Power button behavior
    (lib.mkIf (cfg.enable && cfg.powerButton != null) {
      services.logind.settings.Login.HandlePowerKey = cfg.powerButton;
    })
  ];
}
