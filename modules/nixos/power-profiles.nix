{ config, lib, pkgs, ... }:

let
  cfg = config.smind.power-management;

  powerProfileSwitch = import ../../pkg/power-profile-switch {
    inherit pkgs lib;
    profileOnAC = cfg.profileOnAC;
    profileOnBattery = cfg.profileOnBattery;
    minWatts = cfg.acChargerMinWatts;
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

    acChargerMinWatts = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      example = 60;
      description = ''
        When null (default), profileOnAC is selected whenever any Mains adapter
        is online (legacy behavior).

        When set to a wattage, the USB-PD charger policy is used instead:
        profileOnAC is selected only when a connected USB-PD source advertises
        `unconstrained_power = 1` (a mains wall charger, not a battery-powered
        powerbank) AND its maximum advertised power is at least this many watts;
        otherwise profileOnBattery. This keeps the machine on power-saver when
        running off a powerbank (any wattage) or a weak charger.

        Requires a USB-PD machine exposing /sys/class/usb_power_delivery
        (e.g. Framework laptops). Note: USB-PD does not let us tell a *native*
        charger from any other mains wall charger — identity is not advertised —
        so "unconstrained mains source ≥ N watts" is the finest available cut.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.power-profiles-daemon.enable = true;

    # Switch profile on AC plug/unplug. When the USB-PD policy is active, also
    # react to USB-PD source changes (charger swap / renegotiation that may not
    # toggle the Mains adapter's online state).
    services.udev.extraRules = ''
      SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ACTION=="change", TAG+="systemd", ENV{SYSTEMD_WANTS}="power-profile-switch.service"
    '' + lib.optionalString (cfg.acChargerMinWatts != null) ''
      SUBSYSTEM=="power_supply", ATTR{type}=="USB", ACTION=="change", TAG+="systemd", ENV{SYSTEMD_WANTS}="power-profile-switch.service"
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
