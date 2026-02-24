{ config, lib, pkgs, ... }:

let
  cfg = config.smind.power-management;

  powerProfileSwitch = import ../../pkg/power-profile-switch {
    inherit pkgs lib;
    profileOnAC = cfg.profileOnAC;
    profileOnBattery = cfg.profileOnBattery;
  };
in
{
  options.smind.power-management = {
    profileOnAC = lib.mkOption {
      type = lib.types.enum [ "power-saver" "balanced" "performance" ];
      default = "performance";
      description = "Power profile to use when on AC power";
    };

    profileOnBattery = lib.mkOption {
      type = lib.types.enum [ "power-saver" "balanced" "performance" ];
      default = "power-saver";
      description = "Power profile to use when on battery";
    };
  };

  config = lib.mkIf cfg.enable {
    services.power-profiles-daemon.enable = true;

    # Switch profile on AC plug/unplug
    services.udev.extraRules = ''
      SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ACTION=="change", TAG+="systemd", ENV{SYSTEMD_WANTS}="power-profile-switch.service"
    '';

    systemd.services.power-profile-switch = {
      description = "Switch power profile based on AC status";
      after = [ "power-profiles-daemon.service" ];
      wants = [ "power-profiles-daemon.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = powerProfileSwitch.setProfile;
      };
    };

    # Set correct profile at boot
    systemd.services.power-profile-boot = {
      description = "Set power profile based on AC status at boot";
      wantedBy = [ "power-profiles-daemon.service" ];
      partOf = [ "power-profiles-daemon.service" ];
      after = [ "power-profiles-daemon.service" ];
      wants = [ "power-profiles-daemon.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = powerProfileSwitch.setProfile;
      };
    };
  };
}
