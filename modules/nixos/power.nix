{ config, lib, pkgs, ... }:

let
  cfg = config.smind.power-management;

  refreshRateSwitchScript = pkgs.writeShellScript "refresh-rate-switch" ''
    set -euo pipefail

    MONITOR="${cfg.auto-refresh-rate.monitor}"

    get_refresh_for_profile() {
      case "$1" in
        power-saver) echo "${toString cfg.auto-refresh-rate.onBattery}" ;;
        balanced|performance) echo "${toString cfg.auto-refresh-rate.onAC}" ;;
        *) echo "${toString cfg.auto-refresh-rate.onAC}" ;;
      esac
    }

    set_refresh_rate() {
      local rate="$1"
      echo "Setting refresh rate to ''${rate}Hz"
      if [ -n "$MONITOR" ]; then
        ${pkgs.gnome-randr}/bin/gnome-randr modify "$MONITOR" --rate "$rate" 2>&1 || true
      else
        local monitor
        monitor=$(${pkgs.gnome-randr}/bin/gnome-randr query 2>/dev/null | grep -oP '^\S+' | head -1 || echo "")
        if [ -n "$monitor" ]; then
          ${pkgs.gnome-randr}/bin/gnome-randr modify "$monitor" --rate "$rate" 2>&1 || true
        fi
      fi
    }

    apply_for_profile() {
      local profile="$1"
      local rate
      rate=$(get_refresh_for_profile "$profile")
      echo "Profile '$profile' -> ''${rate}Hz"
      set_refresh_rate "$rate"
    }

    # Apply for current profile
    current_profile=$(${pkgs.power-profiles-daemon}/bin/powerprofilesctl get)
    echo "Initial profile: $current_profile"
    apply_for_profile "$current_profile"

    # Monitor D-Bus for profile changes
    ${pkgs.dbus}/bin/dbus-monitor --system "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='/org/freedesktop/UPower/PowerProfiles'" 2>/dev/null | \
    while read -r line; do
      if echo "$line" | grep -q "ActiveProfile"; then
        # Small delay to let the profile change settle
        sleep 0.2
        new_profile=$(${pkgs.power-profiles-daemon}/bin/powerprofilesctl get)
        if [ "$new_profile" != "$current_profile" ]; then
          echo "Profile changed: $current_profile -> $new_profile"
          current_profile="$new_profile"
          apply_for_profile "$current_profile"
        fi
      fi
    done
  '';
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

    auto-refresh-rate = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Automatically switch display refresh rate based on AC/battery status (GNOME only)";
      };

      onAC = lib.mkOption {
        type = lib.types.int;
        default = 165;
        description = "Refresh rate (Hz) to use when on AC power";
      };

      onBattery = lib.mkOption {
        type = lib.types.int;
        default = 60;
        description = "Refresh rate (Hz) to use when on battery";
      };

      monitor = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Monitor name to control (empty = first monitor). Use 'gnome-randr query' to list.";
      };
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

      # Note: auto-epp is not used when power-profiles-daemon is enabled
      # PPD already manages EPP states and integrates with GNOME

      services.cpupower-gui.enable = true;

      environment.systemPackages = [ pkgs.cpupower-gui ];
    })

    # Auto-switch power-profiles-daemon profiles based on AC/battery
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

    # Auto-switch display refresh rate based on power profile (GNOME/Wayland)
    (lib.mkIf cfg.auto-refresh-rate.enable {
      assertions = [
        {
          assertion = config.smind.desktop.gnome.enable;
          message = "auto-refresh-rate requires smind.desktop.gnome.enable = true";
        }
        {
          assertion = config.services.power-profiles-daemon.enable;
          message = "auto-refresh-rate requires services.power-profiles-daemon.enable = true (monitors profile changes via D-Bus)";
        }
      ];

      environment.systemPackages = [ pkgs.gnome-randr ];

      systemd.user.services.auto-refresh-rate = {
        description = "Automatic display refresh rate switching based on power state";
        wantedBy = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];

        serviceConfig = {
          Type = "simple";
          ExecStart = refreshRateSwitchScript;
          Restart = "on-failure";
          RestartSec = 5;
        };
      };
    })
  ];
}
