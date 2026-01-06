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

  # GNOME version using gdctl (official mutter display control tool)
  refreshRateSwitchScript = pkgs.writeShellScript "refresh-rate-switch" ''
    set -euo pipefail

    MONITOR="${cfg.auto-refresh-rate.monitor}"
    RATE_AC="${toString cfg.auto-refresh-rate.onAC}"
    RATE_BATTERY="${toString cfg.auto-refresh-rate.onBattery}"

    # Parse gdctl show output to get monitor info
    # Returns: CONNECTOR CURRENT_MODE (e.g., "eDP-1 2560x1600@165.000+vrr")
    get_current_config() {
      ${pkgs.mutter}/bin/gdctl show 2>/dev/null | ${pkgs.gawk}/bin/awk '
        /^.*Monitor [A-Za-z]+-[0-9]/ {
          # Extract connector name (e.g., eDP-1)
          match($0, /Monitor ([A-Za-z]+-[0-9]+)/, m)
          if (m[1]) connector = m[1]
        }
        /Current mode/ { in_current = 1; next }
        in_current && /[0-9]+x[0-9]+@[0-9.]+/ {
          # Extract mode (e.g., 2560x1600@165.000 or 2560x1600@165.000+vrr)
          match($0, /([0-9]+x[0-9]+@[0-9.]+(\+vrr)?)/, m)
          if (m[1]) {
            print connector " " m[1]
            exit
          }
        }
      '
    }

    # Parse gdctl show --modes to get available modes for a monitor
    get_available_modes() {
      local monitor="$1"
      ${pkgs.mutter}/bin/gdctl show --modes 2>/dev/null | ${pkgs.gawk}/bin/awk -v mon="$monitor" '
        /Monitor / && $0 ~ mon { in_monitor = 1; next }
        /^.*Monitor [A-Za-z]+-[0-9]/ && in_monitor { exit }
        in_monitor && /[0-9]+x[0-9]+@[0-9.]+/ {
          match($0, /([0-9]+x[0-9]+@[0-9.]+(\+vrr)?)/, m)
          if (m[1]) print m[1]
        }
      '
    }

    # Find best mode matching resolution and target rate, preserving VRR state
    find_best_mode() {
      local current_mode="$1"
      local target_rate="$2"
      local available_modes="$3"

      # Extract resolution and VRR state from current mode
      local resolution vrr_suffix
      resolution=$(echo "$current_mode" | ${pkgs.gnused}/bin/sed 's/@.*//')
      if echo "$current_mode" | ${pkgs.gnugrep}/bin/grep -q '+vrr'; then
        vrr_suffix="+vrr"
      else
        vrr_suffix=""
      fi

      # Find mode with matching resolution and closest refresh rate
      echo "$available_modes" | ${pkgs.gawk}/bin/awk -v res="$resolution" -v rate="$target_rate" -v vrr="$vrr_suffix" '
        BEGIN { best_mode = ""; best_diff = 999999 }
        {
          mode = $1
          # Check if mode has matching VRR state
          has_vrr = (index(mode, "+vrr") > 0)
          want_vrr = (vrr == "+vrr")
          if (has_vrr != want_vrr) next

          # Extract resolution and rate from mode
          clean_mode = mode
          gsub(/\+vrr$/, "", clean_mode)
          split(clean_mode, parts, "@")
          mode_res = parts[1]
          mode_rate = parts[2] + 0

          # Check resolution match
          if (mode_res != res) next

          # Calculate rate difference
          diff = (mode_rate - rate) > 0 ? (mode_rate - rate) : (rate - mode_rate)
          if (diff < best_diff) {
            best_diff = diff
            best_mode = mode
          }
        }
        END { print best_mode }
      '
    }

    set_refresh_rate() {
      local target_rate="$1"

      # Get current configuration
      local config
      config=$(get_current_config)
      if [ -z "$config" ]; then
        echo "Could not get current display configuration"
        return 1
      fi

      local monitor current_mode
      monitor=$(echo "$config" | ${pkgs.gawk}/bin/awk '{print $1}')
      current_mode=$(echo "$config" | ${pkgs.gawk}/bin/awk '{print $2}')

      # Override monitor if specified in config
      if [ -n "$MONITOR" ]; then
        monitor="$MONITOR"
        # Re-fetch current mode for specified monitor
        config=$(${pkgs.mutter}/bin/gdctl show 2>/dev/null | ${pkgs.gawk}/bin/awk -v mon="$MONITOR" '
          /Monitor / && $0 ~ mon { in_monitor = 1; next }
          /^.*Monitor [A-Za-z]+-[0-9]/ && in_monitor { exit }
          in_monitor && /Current mode/ { in_current = 1; next }
          in_monitor && in_current && /[0-9]+x[0-9]+@[0-9.]+/ {
            match($0, /([0-9]+x[0-9]+@[0-9.]+(\+vrr)?)/, m)
            if (m[1]) { print m[1]; exit }
          }
        ')
        current_mode="$config"
      fi

      if [ -z "$monitor" ] || [ -z "$current_mode" ]; then
        echo "Could not determine monitor or current mode"
        return 1
      fi

      # Extract current rate (rounded)
      local current_rate
      current_rate=$(echo "$current_mode" | ${pkgs.gnused}/bin/sed 's/.*@//; s/+vrr//; s/\..*//')

      if [ "$current_rate" = "$target_rate" ]; then
        echo "Already at ''${target_rate}Hz (mode: $current_mode), skipping"
        return 0
      fi

      # Get available modes and find best match
      local available_modes best_mode
      available_modes=$(get_available_modes "$monitor")
      best_mode=$(find_best_mode "$current_mode" "$target_rate" "$available_modes")

      if [ -z "$best_mode" ]; then
        echo "No suitable mode found for ''${target_rate}Hz (current: $current_mode)"
        return 1
      fi

      echo "Setting $monitor: $current_mode -> $best_mode"
      ${pkgs.mutter}/bin/gdctl set -L -M "$monitor" --mode "$best_mode" 2>&1 || true
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
        description = "Monitor name to control (empty = first monitor). Use 'gdctl show' to list.";
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
      # gdctl is included in mutter, no extra packages needed

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
