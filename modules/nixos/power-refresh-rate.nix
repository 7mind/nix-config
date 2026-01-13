{ config, lib, pkgs, ... }:

let
  cfg = config.smind.power-management.auto-refresh-rate;

  # Generate display config lines for GNOME (gdctl)
  # Format: DISPLAY:MODE_AC:MODE_BATTERY:IS_PRIMARY
  gnomeDisplayConfigLines = lib.concatStringsSep "\n" (lib.filter (x: x != "") (lib.mapAttrsToList
    (name: dcfg:
      if dcfg.gnome != null
      then "${name}:${dcfg.gnome.onAC}:${dcfg.gnome.onBattery}:${if dcfg.primary then "1" else "0"}"
      else "")
    cfg.displays));

  # Generate display config lines for COSMIC (wlr-randr)
  # Format: DISPLAY:MODE_AC:MODE_BATTERY
  cosmicDisplayConfigLines = lib.concatStringsSep "\n" (lib.filter (x: x != "") (lib.mapAttrsToList
    (name: dcfg:
      if dcfg.cosmic != null
      then "${name}:${dcfg.cosmic.onAC}:${dcfg.cosmic.onBattery}"
      else "")
    cfg.displays));

  refreshRateScripts = import ../../pkg/power-refresh-rate {
    inherit pkgs lib;
    inherit gnomeDisplayConfigLines cosmicDisplayConfigLines;
  };
in
{
  options.smind.power-management.auto-refresh-rate = {
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
      default = { };
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

  config = lib.mkMerge [
    # udev trigger for refresh rate updates (shared by GNOME and COSMIC)
    (lib.mkIf cfg.enable {
      services.udev.extraRules = ''
        SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ACTION=="change", RUN+="${refreshRateScripts.triggerRefreshRateUpdate}"
      '';
    })

    # GNOME/Wayland refresh rate switching
    (lib.mkIf (cfg.enable && config.smind.desktop.gnome.enable) {
      # Path unit watches for trigger file changes
      systemd.user.paths.auto-refresh-rate-gnome = {
        description = "Watch for power state changes to update refresh rate";
        wantedBy = [ "gnome-session.target" ];
        pathConfig = {
          PathChanged = "%t/refresh-rate-trigger";
          Unit = "auto-refresh-rate-gnome.service";
          TriggerLimitIntervalSec = 2;
          TriggerLimitBurst = 1;
        };
      };

      # Oneshot service applies correct refresh rate
      systemd.user.services.auto-refresh-rate-gnome = {
        description = "Apply display refresh rate based on power state (GNOME)";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = refreshRateScripts.gnomeSetRefreshRate;
        };
      };

      # Apply on login
      systemd.user.services.auto-refresh-rate-gnome-init = {
        description = "Set initial display refresh rate based on power state (GNOME)";
        wantedBy = [ "gnome-session.target" ];
        after = [ "gnome-session.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = refreshRateScripts.gnomeSetRefreshRate;
          RemainAfterExit = true;
        };
      };
    })

    # COSMIC/Wayland refresh rate switching
    (lib.mkIf (cfg.enable && config.smind.desktop.cosmic.enable) {
      environment.systemPackages = [ pkgs.wlr-randr ];

      # Path unit watches for trigger file changes
      systemd.user.paths.auto-refresh-rate-cosmic = {
        description = "Watch for power state changes to update refresh rate";
        wantedBy = [ "cosmic-session.target" ];
        pathConfig = {
          PathChanged = "%t/refresh-rate-trigger";
          Unit = "auto-refresh-rate-cosmic.service";
          TriggerLimitIntervalSec = 2;
          TriggerLimitBurst = 1;
        };
      };

      # Oneshot service applies correct refresh rate
      systemd.user.services.auto-refresh-rate-cosmic = {
        description = "Apply display refresh rate based on power state (COSMIC)";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = refreshRateScripts.cosmicSetRefreshRate;
        };
      };

      # Apply on login
      systemd.user.services.auto-refresh-rate-cosmic-init = {
        description = "Set initial display refresh rate based on power state (COSMIC)";
        wantedBy = [ "cosmic-session.target" ];
        after = [ "cosmic-session.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = refreshRateScripts.cosmicSetRefreshRate;
          RemainAfterExit = true;
        };
      };
    })
  ];
}
