{ config, lib, pkgs, ... }:

let
  cfg = config.smind.power-management;

  # COSMIC version using cosmic-randr
  cosmicRefreshRateSwitchScript = pkgs.writeShellScript "refresh-rate-switch-cosmic" ''
    set -euo pipefail

    MONITOR="${cfg.auto-refresh-rate.monitor}"
    RATE_AC="${toString cfg.auto-refresh-rate.onAC}"
    RATE_BATTERY="${toString cfg.auto-refresh-rate.onBattery}"

    get_monitor_info() {
      # Get first monitor if not specified, and its current resolution
      local output
      output=$(${pkgs.cosmic-randr}/bin/cosmic-randr list 2>&1) || true

      echo "DEBUG: cosmic-randr output:" >&2
      echo "$output" >&2
      echo "DEBUG: end output" >&2

      if [ -z "$output" ]; then
        echo "DEBUG: cosmic-randr returned empty output" >&2
        return 1
      fi

      if [ -n "$MONITOR" ]; then
        echo "$output" | ${pkgs.gawk}/bin/awk -v mon="$MONITOR" '
          $1 == mon { found=1 }
          found && /\(current\)/ {
            # Line: "    2560x1600 @ 165.000 Hz (current)"
            # Extract resolution by finding NNNNxNNNN pattern
            if (match($0, /[0-9]+x[0-9]+/)) {
              res = substr($0, RSTART, RLENGTH)
              split(res, dims, "x")
              print mon, dims[1], dims[2]
            }
            exit
          }
        '
      else
        # Find first monitor and its current mode
        # cosmic-randr format: "eDP-1 (enabled)" for monitor header
        # and "    2560x1600 @ 165.000 Hz (current)" for modes
        echo "$output" | ${pkgs.gawk}/bin/awk '
          /^[A-Za-z]+-?[0-9]/ {
            mon=$1
            print "DEBUG AWK: found monitor:", mon > "/dev/stderr"
          }
          mon && /\(current\)/ {
            print "DEBUG AWK: found current line:", $0 > "/dev/stderr"
            if (match($0, /[0-9]+x[0-9]+/)) {
              res = substr($0, RSTART, RLENGTH)
              print "DEBUG AWK: extracted res:", res > "/dev/stderr"
              split(res, dims, "x")
              print mon, dims[1], dims[2]
            } else {
              print "DEBUG AWK: no resolution match" > "/dev/stderr"
            }
            exit
          }
        '
      fi
    }

    set_refresh_rate() {
      local rate="$1"
      local info
      info=$(get_monitor_info)

      if [ -z "$info" ]; then
        echo "No monitor found"
        return 1
      fi

      local monitor width height
      read -r monitor width height <<< "$info"

      echo "Setting $monitor to ''${width}x''${height}@''${rate}Hz"
      ${pkgs.cosmic-randr}/bin/cosmic-randr mode "$monitor" "$width" "$height" --refresh "$rate" 2>&1 || true
    }

    is_on_battery() {
      local state
      state=$(${pkgs.upower}/bin/upower -i /org/freedesktop/UPower/devices/DisplayDevice 2>/dev/null | \
        ${pkgs.gawk}/bin/awk '/state:/ {print $2}')
      [ "$state" = "discharging" ]
    }

    apply_for_power_state() {
      if is_on_battery; then
        echo "On battery -> ''${RATE_BATTERY}Hz"
        set_refresh_rate "$RATE_BATTERY"
      else
        echo "On AC -> ''${RATE_AC}Hz"
        set_refresh_rate "$RATE_AC"
      fi
    }

    echo "Checking initial power state..."
    apply_for_power_state

    echo "Monitoring UPower DisplayDevice for power state changes..."
    ${pkgs.dbus}/bin/dbus-monitor --system "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='/org/freedesktop/UPower/devices/DisplayDevice'" 2>/dev/null | \
    while read -r line; do
      if echo "$line" | ${pkgs.gnugrep}/bin/grep -qE "State|IsPresent"; then
        sleep 0.3
        echo "Power state changed"
        apply_for_power_state
      fi
    done
  '';

  # GNOME version using gnome-randr
  refreshRateSwitchScript = pkgs.writeShellScript "refresh-rate-switch" ''
    set -euo pipefail

    MONITOR="${cfg.auto-refresh-rate.monitor}"
    RATE_AC="${toString cfg.auto-refresh-rate.onAC}"
    RATE_BATTERY="${toString cfg.auto-refresh-rate.onBattery}"

    get_monitor_name() {
      if [ -n "$MONITOR" ]; then
        echo "$MONITOR"
      else
        # Find first line that looks like a monitor name (eDP-1, DP-1, HDMI-1, etc.)
        ${pkgs.gnome-randr}/bin/gnome-randr query 2>/dev/null | \
          ${pkgs.gawk}/bin/awk '/^(eDP|DP|HDMI|VGA|DVI)-[0-9]/ {print $1; exit}'
      fi
    }

    get_current_resolution() {
      local monitor="$1"
      # Find line with * (current mode) under the monitor section
      # Format: "  2560x1600@165.000  2560x1600  165.00*  [scales]"
      ${pkgs.gnome-randr}/bin/gnome-randr query 2>/dev/null | \
        ${pkgs.gawk}/bin/awk -v mon="$monitor" '
          $1 == mon { in_monitor = 1; next }
          /^[A-Za-z]/ && !/^[[:space:]]/ && in_monitor { exit }
          in_monitor && /\*/ {
            # First field after trimming is the mode (e.g., 2560x1600@165.000)
            gsub(/^[[:space:]]+/, "")
            split($1, parts, "@")
            print parts[1]
            exit
          }
        '
    }

    find_best_mode() {
      local monitor="$1"
      local resolution="$2"
      local target_rate="$3"
      # Find mode matching resolution with rate closest to target
      # Prefer non-VRR modes (without +vrr suffix)
      ${pkgs.gnome-randr}/bin/gnome-randr query 2>/dev/null | \
        ${pkgs.gawk}/bin/awk -v mon="$monitor" -v res="$resolution" -v rate="$target_rate" '
          BEGIN { best_mode = ""; best_diff = 999999; best_has_vrr = 1 }
          $1 == mon { in_monitor = 1; next }
          /^[A-Za-z]/ && !/^[[:space:]]/ && in_monitor { exit }
          in_monitor && /^[[:space:]]/ {
            gsub(/^[[:space:]]+/, "")
            mode = $1
            has_vrr = (index(mode, "+vrr") > 0)
            clean_mode = mode
            gsub(/\+vrr$/, "", clean_mode)
            if (index(clean_mode, res "@") == 1) {
              split(clean_mode, parts, "@")
              mode_rate = parts[2] + 0
              diff = (mode_rate - rate) > 0 ? (mode_rate - rate) : (rate - mode_rate)
              # Prefer non-VRR modes, then closest rate
              if (diff < best_diff || (diff == best_diff && !has_vrr && best_has_vrr)) {
                best_diff = diff
                best_mode = clean_mode
                best_has_vrr = has_vrr
              }
            }
          }
          END { print best_mode }
        '
    }

    set_refresh_rate() {
      local rate="$1"
      local monitor
      monitor=$(get_monitor_name)
      if [ -z "$monitor" ]; then
        echo "No monitor found"
        return 1
      fi

      local resolution
      resolution=$(get_current_resolution "$monitor")
      if [ -z "$resolution" ]; then
        echo "Could not determine current resolution for $monitor"
        return 1
      fi

      local mode
      mode=$(find_best_mode "$monitor" "$resolution" "$rate")
      if [ -z "$mode" ]; then
        echo "No suitable mode found for ''${resolution}@''${rate}Hz"
        return 1
      fi

      echo "Setting $monitor to mode $mode"
      ${pkgs.gnome-randr}/bin/gnome-randr modify "$monitor" --mode "$mode" 2>&1 || true
    }

    is_on_battery() {
      # Check DisplayDevice state - "discharging" means on battery
      local state
      state=$(${pkgs.upower}/bin/upower -i /org/freedesktop/UPower/devices/DisplayDevice 2>/dev/null | \
        ${pkgs.gawk}/bin/awk '/state:/ {print $2}')
      [ "$state" = "discharging" ]
    }

    apply_for_power_state() {
      if is_on_battery; then
        echo "On battery -> ''${RATE_BATTERY}Hz"
        set_refresh_rate "$RATE_BATTERY"
      else
        echo "On AC -> ''${RATE_AC}Hz"
        set_refresh_rate "$RATE_AC"
      fi
    }

    # Apply for current power state
    echo "Checking initial power state..."
    apply_for_power_state

    # Monitor DisplayDevice for state changes
    echo "Monitoring UPower DisplayDevice for power state changes..."
    ${pkgs.dbus}/bin/dbus-monitor --system "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='/org/freedesktop/UPower/devices/DisplayDevice'" 2>/dev/null | \
    while read -r line; do
      if echo "$line" | ${pkgs.gnugrep}/bin/grep -qE "State|IsPresent"; then
        sleep 0.3
        echo "Power state changed"
        apply_for_power_state
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
        description = "Automatically switch display refresh rate based on AC/battery status via UPower (GNOME/COSMIC Wayland)";
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
    (lib.mkIf cfg.auto-profile.enable (
      let
        setProfileScript = pkgs.writeShellScript "power-profile-set" ''
          # Check if any AC adapter is online
          for supply in /sys/class/power_supply/*/; do
            if [ -f "$supply/type" ] && [ "$(cat "$supply/type")" = "Mains" ]; then
              if [ -f "$supply/online" ] && [ "$(cat "$supply/online")" = "1" ]; then
                ${pkgs.power-profiles-daemon}/bin/powerprofilesctl set ${cfg.auto-profile.onAC}
                exit 0
              fi
            fi
          done
          # No AC found, use battery profile
          ${pkgs.power-profiles-daemon}/bin/powerprofilesctl set ${cfg.auto-profile.onBattery}
        '';
      in {
        assertions = [{
          assertion = config.services.power-profiles-daemon.enable;
          message = "auto-profile requires services.power-profiles-daemon.enable = true";
        }];

        # Use acpid for AC plug/unplug events
        services.acpid.enable = true;
        services.acpid.acEventCommands = "${setProfileScript}";

        # Set correct power profile at boot (acpid only fires on events, not boot)
        systemd.services.power-profile-boot = {
          description = "Set power profile based on AC status at boot";
          wantedBy = [ "multi-user.target" ];
          after = [ "power-profiles-daemon.service" ];
          requires = [ "power-profiles-daemon.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = setProfileScript;
          };
        };
      }
    ))

    # Auto-switch display refresh rate based on AC/battery (GNOME/Wayland)
    (lib.mkIf (cfg.auto-refresh-rate.enable && config.smind.desktop.gnome.enable) {
      environment.systemPackages = [ pkgs.gnome-randr ];

      systemd.user.services.auto-refresh-rate-gnome = {
        description = "Automatic display refresh rate switching based on power state (GNOME)";
        wantedBy = [ "gnome-session.target" ];
        after = [ "gnome-session.target" ];
        partOf = [ "gnome-session.target" ];

        serviceConfig = {
          Type = "simple";
          ExecStart = refreshRateSwitchScript;
          Restart = "on-failure";
          RestartSec = 5;
        };
      };
    })

    # Auto-switch display refresh rate based on AC/battery (COSMIC/Wayland)
    (lib.mkIf (cfg.auto-refresh-rate.enable && config.smind.desktop.cosmic.enable) {
      environment.systemPackages = [ pkgs.cosmic-randr ];

      systemd.user.services.auto-refresh-rate-cosmic = {
        description = "Automatic display refresh rate switching based on power state (COSMIC)";
        wantedBy = [ "cosmic-session.target" ];
        after = [ "cosmic-session.target" ];
        partOf = [ "cosmic-session.target" ];

        serviceConfig = {
          Type = "simple";
          ExecStart = cosmicRefreshRateSwitchScript;
          Restart = "on-failure";
          RestartSec = 5;
        };

        # cosmic-randr needs Wayland environment
        environment = {
          WAYLAND_DISPLAY = "wayland-1";
          XDG_RUNTIME_DIR = "%t";
        };
      };
    })
  ];
}
