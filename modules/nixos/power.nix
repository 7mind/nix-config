{ config, lib, pkgs, ... }:

let
  cfg = config.smind.power-management;

  # Shared: check if on battery
  isOnBatteryCheck = ''
    is_on_ac() {
      for supply in /sys/class/power_supply/*/; do
        if [ -f "$supply/type" ] && [ "$(cat "$supply/type")" = "Mains" ]; then
          if [ -f "$supply/online" ] && [ "$(cat "$supply/online")" = "1" ]; then
            return 0
          fi
        fi
      done
      return 1
    }
  '';

  # Generate display config lines for GNOME (gdctl)
  # Format: DISPLAY:MODE_AC:MODE_BATTERY:IS_PRIMARY
  gnomeDisplayConfigLines = lib.concatStringsSep "\n" (lib.filter (x: x != "") (lib.mapAttrsToList
    (name: dcfg:
      if dcfg.gnome != null
      then "${name}:${dcfg.gnome.onAC}:${dcfg.gnome.onBattery}:${if dcfg.primary then "1" else "0"}"
      else "")
    cfg.auto-refresh-rate.displays));

  # Generate display config lines for COSMIC (wlr-randr)
  # Format: DISPLAY:MODE_AC:MODE_BATTERY
  cosmicDisplayConfigLines = lib.concatStringsSep "\n" (lib.filter (x: x != "") (lib.mapAttrsToList
    (name: dcfg:
      if dcfg.cosmic != null
      then "${name}:${dcfg.cosmic.onAC}:${dcfg.cosmic.onBattery}"
      else "")
    cfg.auto-refresh-rate.displays));

  # COSMIC: set refresh rate using wlr-randr
  cosmicSetRefreshRate = pkgs.writeShellScript "refresh-rate-set-cosmic" ''
    set -euo pipefail
    ${isOnBatteryCheck}

    if is_on_ac; then
      echo "On AC power"
      MODE_IDX=1
    else
      echo "On battery"
      MODE_IDX=2
    fi

    # Process each configured display
    while IFS=: read -r display mode_ac mode_battery; do
      [ -z "$display" ] && continue
      if [ "$MODE_IDX" = "1" ]; then
        target_mode="$mode_ac"
      else
        target_mode="$mode_battery"
      fi
      echo "Setting $display -> $target_mode"
      ${pkgs.wlr-randr}/bin/wlr-randr --output "$display" --mode "$target_mode" 2>&1 || true
    done <<'DISPLAYS'
    ${cosmicDisplayConfigLines}
    DISPLAYS
  '';

  # GNOME: set refresh rate using gdctl
  gnomeSetRefreshRate = pkgs.writeShellScript "refresh-rate-set-gnome" ''
    set -euo pipefail
    ${isOnBatteryCheck}

    if is_on_ac; then
      echo "On AC power"
      MODE_IDX=1
    else
      echo "On battery"
      MODE_IDX=2
    fi

    # Build gdctl command with all displays
    args=""
    while IFS=: read -r display mode_ac mode_battery is_primary; do
      [ -z "$display" ] && continue
      if [ "$MODE_IDX" = "1" ]; then
        target_mode="$mode_ac"
      else
        target_mode="$mode_battery"
      fi
      primary_flag=""
      [ "$is_primary" = "1" ] && primary_flag="--primary"
      args="$args -L $primary_flag -M $display --mode $target_mode"
      echo "Setting $display -> $target_mode"
    done <<'DISPLAYS'
    ${gnomeDisplayConfigLines}
    DISPLAYS

    [ -n "$args" ] && ${pkgs.mutter}/bin/gdctl set $args 2>&1 || true
  '';

  # System script to signal user services (called by udev on power state change)
  triggerRefreshRateUpdate = pkgs.writeShellScript "trigger-refresh-rate-update" ''
    # Signal all graphical user sessions to update refresh rate
    ${pkgs.systemd}/bin/loginctl list-sessions --no-legend | while read -r session rest; do
      user=$(${pkgs.systemd}/bin/loginctl show-session "$session" -p Name --value 2>/dev/null)
      type=$(${pkgs.systemd}/bin/loginctl show-session "$session" -p Type --value 2>/dev/null)
      [ "$type" = "wayland" ] || [ "$type" = "x11" ] || continue
      uid=$(id -u "$user" 2>/dev/null) || continue
      runtime_dir="/run/user/$uid"
      trigger_file="$runtime_dir/refresh-rate-trigger"
      # Create/update trigger file with user ownership so path unit can watch it
      if [ -d "$runtime_dir" ]; then
        touch "$trigger_file" 2>/dev/null || true
        chown "$uid:$uid" "$trigger_file" 2>/dev/null || true
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

    tuned = {
      onAC = lib.mkOption {
        type = lib.types.str;
        default = "latency-performance";
        example = "balanced";
        description = "TuneD profile to use when on AC power (can't use throughput-performance - reserved for PPD performance profile)";
      };

      onBattery = lib.mkOption {
        type = lib.types.str;
        default = "powersave";
        example = "balanced-battery";
        description = "TuneD profile to use when on battery";
      };
    };

    auto-refresh-rate = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Automatically switch display refresh rate based on AC/battery status (GNOME/COSMIC Wayland)";
      };

      displays = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            gnome = lib.mkOption {
              type = lib.types.nullOr (lib.types.submodule {
                options = {
                  onAC = lib.mkOption {
                    type = lib.types.str;
                    example = "2560x1600@165.000+vrr";
                    description = "Mode for AC power. Get from 'gdctl show --modes'.";
                  };
                  onBattery = lib.mkOption {
                    type = lib.types.str;
                    example = "2560x1600@60.002+vrr";
                    description = "Mode for battery.";
                  };
                };
              });
              default = null;
              description = "GNOME/gdctl mode configuration.";
            };
            cosmic = lib.mkOption {
              type = lib.types.nullOr (lib.types.submodule {
                options = {
                  onAC = lib.mkOption {
                    type = lib.types.str;
                    example = "2560x1600@165Hz";
                    description = "Mode for AC power. Get from 'wlr-randr'.";
                  };
                  onBattery = lib.mkOption {
                    type = lib.types.str;
                    example = "2560x1600@60Hz";
                    description = "Mode for battery.";
                  };
                };
              });
              default = null;
              description = "COSMIC/wlr-randr mode configuration.";
            };
            primary = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether this is the primary display (for GNOME gdctl).";
            };
          };
        });
        default = {};
        example = lib.literalExpression ''
          {
            "eDP-1" = {
              gnome = {
                onAC = "2560x1600@165.000+vrr";
                onBattery = "2560x1600@60.002+vrr";
              };
              cosmic = {
                onAC = "2560x1600@165Hz";
                onBattery = "2560x1600@60Hz";
              };
            };
          }
        '';
        description = "Per-display mode configuration for AC/battery power states.";
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

      services.cpupower-gui.enable = true;

      environment.systemPackages = [ pkgs.cpupower-gui ];
    })

    # TuneD - automatic AC/battery profile switching via UPower
    (lib.mkIf cfg.enable {
      services.tuned.enable = true;
      services.upower.enable = true; # Required for battery detection

      # Configure TuneD profiles for AC/battery states
      # All three PPD profiles must be defined (tuned-ppd requires them)
      services.tuned.ppdSettings = {
        profiles = {
          power-saver = "powersave";
          balanced = cfg.tuned.onAC;
          performance = "throughput-performance";
        };
        battery.balanced = cfg.tuned.onBattery;
      };

      # CLI tools: tuned-adm, powerprofilesctl
      environment.systemPackages = [
        config.services.tuned.package
        pkgs.power-profiles-daemon # for powerprofilesctl CLI
      ];
    })

    # Auto-switch display refresh rate based on AC/battery (udev trigger)
    (lib.mkIf cfg.auto-refresh-rate.enable {
      services.udev.extraRules = ''
        SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ACTION=="change", RUN+="${triggerRefreshRateUpdate}"
      '';
    })

    # Auto-switch display refresh rate based on AC/battery (GNOME/Wayland)
    (lib.mkIf (cfg.auto-refresh-rate.enable && config.smind.desktop.gnome.enable) {
      # Path unit watches for trigger file changes
      systemd.user.paths.auto-refresh-rate-gnome = {
        description = "Watch for power state changes to update refresh rate";
        wantedBy = [ "gnome-session.target" ];
        pathConfig = {
          PathChanged = "%t/refresh-rate-trigger";
          Unit = "auto-refresh-rate-gnome.service";
        };
      };

      # Oneshot service applies correct refresh rate
      systemd.user.services.auto-refresh-rate-gnome = {
        description = "Apply display refresh rate based on power state (GNOME)";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = gnomeSetRefreshRate;
        };
      };

      # Apply on login
      systemd.user.services.auto-refresh-rate-gnome-init = {
        description = "Set initial display refresh rate based on power state (GNOME)";
        wantedBy = [ "gnome-session.target" ];
        after = [ "gnome-session.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = gnomeSetRefreshRate;
          RemainAfterExit = true;
        };
      };
    })

    # Auto-switch display refresh rate based on AC/battery (COSMIC/Wayland)
    (lib.mkIf (cfg.auto-refresh-rate.enable && config.smind.desktop.cosmic.enable) {
      environment.systemPackages = [ pkgs.wlr-randr ];

      # Path unit watches for trigger file changes
      systemd.user.paths.auto-refresh-rate-cosmic = {
        description = "Watch for power state changes to update refresh rate";
        wantedBy = [ "cosmic-session.target" ];
        pathConfig = {
          PathChanged = "%t/refresh-rate-trigger";
          Unit = "auto-refresh-rate-cosmic.service";
        };
      };

      # Oneshot service applies correct refresh rate
      systemd.user.services.auto-refresh-rate-cosmic = {
        description = "Apply display refresh rate based on power state (COSMIC)";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = cosmicSetRefreshRate;
        };
      };

      # Apply on login
      systemd.user.services.auto-refresh-rate-cosmic-init = {
        description = "Set initial display refresh rate based on power state (COSMIC)";
        wantedBy = [ "cosmic-session.target" ];
        after = [ "cosmic-session.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = cosmicSetRefreshRate;
          RemainAfterExit = true;
        };
      };
    })
  ];
}
