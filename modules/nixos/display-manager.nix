{ config, lib, pkgs, ... }:

let
  # Priority-based backend selection
  # Priority: KDE > GNOME > COSMIC
  selectedBackend =
    if config.smind.display-manager != "auto" then config.smind.display-manager
    else if config.smind.desktop.kde.enable then "sddm"
    else if config.smind.desktop.gnome.enable then "gdm"
    else if config.smind.desktop.cosmic.enable then "cosmic-greeter"
    else "none";

  # Count enabled desktops
  enabledDesktops = lib.filter (x: x != null) [
    (if config.smind.desktop.kde.enable then "KDE" else null)
    (if config.smind.desktop.gnome.enable then "GNOME" else null)
    (if config.smind.desktop.cosmic.enable then "COSMIC" else null)
  ];
  hasMultipleDesktops = builtins.length enabledDesktops > 1;

in
{
  options.smind = {
    display-manager = lib.mkOption {
      type = lib.types.enum [ "auto" "gdm" "sddm" "cosmic-greeter" "greetd" "none" ];
      default = "auto";
      description = ''
        Display manager to use.

      - auto: Automatically select based on priority: KDE > GNOME > COSMIC
      - gdm: GNOME Display Manager
      - sddm: Simple Desktop Display Manager (KDE default)
      - cosmic-greeter: COSMIC greeter
      - greetd: Generic greeter
      - none: No display manager (manual startx/login)

        Priority ensures deterministic selection regardless of module evaluation order.
      '';
    };

    auto-login = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable automatic login (use with disk encryption for security)";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "User to automatically log in";
      };
    };

    x11.enable = lib.mkEnableOption "x11-server";
  };

  config = lib.mkMerge [
    # Info message for multiple desktops
    {
      warnings = lib.optionals (hasMultipleDesktops && config.smind.display-manager == "auto") [
        ''
          Multiple desktop environments enabled: ${lib.concatStringsSep ", " enabledDesktops}
          Auto-selected display manager: ${selectedBackend} (priority: KDE > GNOME > COSMIC)

          All desktops will be available as sessions at login.
          To override, set: smind.display-manager = "gdm" | "sddm" | "cosmic-greeter"
        ''
      ];

      assertions = [
        {
          assertion = selectedBackend != "auto";
          message = "Display manager backend could not be determined";
        }
      ];
    }

    # Auto-login configuration
    (lib.mkIf config.smind.auto-login.enable {
      assertions = [{
        assertion = config.smind.auto-login.user != "";
        message = "smind.auto-login.user must be set when auto-login is enabled";
      }];

      services.displayManager.autoLogin = {
        enable = true;
        user = config.smind.auto-login.user;
      };
    })

    # GDM configuration
    (lib.mkIf (selectedBackend == "gdm") {
      services.xserver.enable = true;
      services.displayManager.gdm.enable = true;

      # Speed up GDM startup
      systemd.services.display-manager.after = [ "systemd-user-sessions.service" ];

      # GDM login screen settings (runs as gdm user, needs separate profile)
      programs.dconf.profiles.gdm.databases = lib.mkIf config.smind.desktop.gnome.enable [
        {
          lockAll = true;
          settings = lib.mkMerge ([
            {
              "org/gnome/desktop/interface" = {
                cursor-size = lib.gvariant.mkInt32 36;
                color-scheme = "prefer-dark";
              };
              # Required for fractional scaling in monitors.xml to work
              "org/gnome/mutter" = {
                experimental-features =
                  lib.optionals config.smind.desktop.gnome.fractional-scaling.enable [
                    "scale-monitor-framebuffer"
                  ];
              };
            }
          ] ++ lib.optional (!config.smind.desktop.gnome.auto-suspend.enable) {
            "org/gnome/settings-daemon/plugins/power" = {
              sleep-inactive-ac-type = "nothing";
              sleep-inactive-battery-type = "nothing";
            };
          });
        }
      ];

      # Symlink monitors.xml to GDM for consistent display resolution on login screen
      systemd.tmpfiles.rules = lib.mkIf
        (config.smind.desktop.gnome.enable
          && config.smind.desktop.gnome.gdm.monitors-xml != null) [
        "L+ /run/gdm/.config/monitors.xml - - - - ${config.smind.desktop.gnome.gdm.monitors-xml}"
      ];
    })

    # SDDM configuration
    (lib.mkIf (selectedBackend == "sddm") {
      services.displayManager.sddm = {
        enable = true;
        wayland.enable = lib.mkDefault true;
        enableHidpi = lib.mkDefault true;

        # KDE-specific SDDM settings (from kde.nix)
        wayland.compositor = lib.mkIf config.smind.desktop.kde.enable (lib.mkDefault "kwin");
        settings = lib.mkIf config.smind.desktop.kde.enable {
          Theme.CursorTheme = lib.mkDefault "breeze_cursors";
          Users = {
            RememberLastUser = lib.mkDefault true;
            RememberLastSession = lib.mkDefault true;
          };
        };
      };
    })

    # COSMIC greeter configuration
    (lib.mkIf (selectedBackend == "cosmic-greeter") {
      services.displayManager.cosmic-greeter.enable = true;
    })

    # greetd configuration
    (lib.mkIf (selectedBackend == "greetd") {
      services.greetd = {
        enable = true;
        settings = {
          default_session.command = lib.mkDefault "${pkgs.greetd.tuigreet}/bin/tuigreet --time --cmd sway";
        };
      };
    })

    # x11
    (lib.mkIf (config.smind.x11.enable) {
      services.xserver.enable = true;
    })
  ];
}
