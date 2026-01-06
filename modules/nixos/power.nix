{ config, lib, pkgs, ... }:

let
  cfg = config.smind.power-management;

  # COSMIC/Wayland version using wlr-randr with JSON output
  cosmicRefreshRateSwitchScript = pkgs.writeShellScript "refresh-rate-switch-wayland" ''
    set -euo pipefail

    # Import environment from systemd user manager
    eval "$(${pkgs.systemd}/bin/systemctl --user show-environment | grep -E '^(WAYLAND_DISPLAY|DISPLAY|DBUS_SESSION_BUS_ADDRESS)=')" 2>/dev/null || true
    export WAYLAND_DISPLAY DISPLAY DBUS_SESSION_BUS_ADDRESS 2>/dev/null || true

    # Fallback: try to find wayland socket
    if [ -z "''${WAYLAND_DISPLAY:-}" ] && [ -d "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" ]; then
      for sock in "''${XDG_RUNTIME_DIR}"/wayland-*; do
        if [ -S "$sock" ]; then
          export WAYLAND_DISPLAY="$(basename "$sock")"
          break
        fi
      done
    fi

    MONITOR="${cfg.auto-refresh-rate.monitor}"
    RATE_AC="${toString cfg.auto-refresh-rate.onAC}"
    RATE_BATTERY="${toString cfg.auto-refresh-rate.onBattery}"

    set_refresh_rate() {
      local rate="$1"
      local json
      json=$(${pkgs.wlr-randr}/bin/wlr-randr --json 2>/dev/null) || return 1

      # Find monitor (first enabled if not specified)
      local monitor
      if [ -n "$MONITOR" ]; then
        monitor="$MONITOR"
      else
        monitor=$(echo "$json" | ${pkgs.jq}/bin/jq -r '.[0].name // empty')
      fi

      if [ -z "$monitor" ]; then
        echo "No monitor found"
        return 1
      fi

      # Get current refresh rate (rounded)
      local current_rate
      current_rate=$(echo "$json" | ${pkgs.jq}/bin/jq -r --arg mon "$monitor" '
        .[] | select(.name == $mon) | .modes[] | select(.current) | .refresh | round
      ')

      if [ "$current_rate" = "$rate" ]; then
        echo "Already at ''${rate}Hz, skipping"
        return 0
      fi

      # Find mode matching target rate (within 1 Hz tolerance)
      local mode
      mode=$(echo "$json" | ${pkgs.jq}/bin/jq -r --arg mon "$monitor" --argjson rate "$rate" '
        .[] | select(.name == $mon) | .modes[] |
        select((.refresh | round) == $rate or ((.refresh - $rate) | fabs) < 1) |
        "\(.width)x\(.height)@\(.refresh)"
      ' | head -1)

      if [ -z "$mode" ]; then
        echo "No matching mode found for ''${rate}Hz"
        return 1
      fi

      echo "Setting $monitor to $mode"
      ${pkgs.wlr-randr}/bin/wlr-randr --output "$monitor" --mode "$mode" 2>&1 || true
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

    get_current_rate() {
      local monitor="$1"
      # Get current refresh rate (rounded to nearest integer)
      ${pkgs.gnome-randr}/bin/gnome-randr query 2>/dev/null | \
        ${pkgs.gawk}/bin/awk -v mon="$monitor" '
          $1 == mon { in_monitor = 1; next }
          /^[A-Za-z]/ && !/^[[:space:]]/ && in_monitor { exit }
          in_monitor && /\*/ {
            gsub(/^[[:space:]]+/, "")
            split($1, parts, "@")
            print int(parts[2] + 0.5)
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

      # Check if already at target rate
      local current_rate
      current_rate=$(get_current_rate "$monitor")
      if [ "$current_rate" = "$rate" ]; then
        echo "Already at ''${rate}Hz, skipping"
        return 0
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
      environment.systemPackages = [ pkgs.wlr-randr ];

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

        # Delay start to ensure COSMIC output management is ready
        unitConfig = {
          StartLimitIntervalSec = 60;
          StartLimitBurst = 3;
        };
      };

    })
  ];
}
