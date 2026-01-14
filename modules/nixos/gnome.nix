{ config, lib, pkgs, cfg-meta, ... }:

{
  options = {
    smind.desktop.gnome.enable = lib.mkEnableOption "GNOME desktop environment with GDM";

    smind.desktop.gnome.auto-suspend.onAC = lib.mkOption {
      type = lib.types.enum [ "nothing" "suspend" "hibernate" "blank" ];
      default = if config.smind.isLaptop then "suspend" else "nothing";
      description = "Action when idle on AC power";
    };

    smind.desktop.gnome.auto-suspend.onBattery = lib.mkOption {
      type = lib.types.enum [ "nothing" "suspend" "hibernate" "blank" ];
      default = "suspend";
      description = "Action when idle on battery";
    };

    smind.desktop.gnome.auto-suspend.timeoutAC = lib.mkOption {
      type = lib.types.int;
      default = 7200; # 2 hours
      description = "Idle timeout in seconds before action on AC power";
    };

    smind.desktop.gnome.auto-suspend.timeoutBattery = lib.mkOption {
      type = lib.types.int;
      default = 900; # 15 minutes
      description = "Idle timeout in seconds before action on battery";
    };

    smind.desktop.gnome.fractional-scaling.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable fractional scaling via Mutter experimental features";
    };

    smind.desktop.gnome.vrr.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Variable Refresh Rate (VRR) via Mutter experimental features";
    };

    smind.desktop.gnome.hot-corners.enable = lib.mkEnableOption "GNOME hot corners";

    smind.desktop.gnome.switch-input-source-keybinding = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "<Ctrl><Alt><Super>space" ];
      description = "Keybinding(s) for switching to next input source (in addition to xkb-options)";
    };

    smind.desktop.gnome.sticky-keys.enable = lib.mkEnableOption "sticky keys with GNOME Shell keyboard-modifiers-status extension";

    smind.desktop.gnome.gdm.monitors-xml = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./monitors.xml";
      description = "Path to monitors.xml for GDM login screen display configuration";
    };

    smind.desktop.gnome.xkb.layouts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = config.smind.desktop.xkb.layouts;
      example = [ "us+dvorak" "de" "fr+azerty" ];
      description = ''
        XKB keyboard layouts for GNOME in "layout+variant" format.
        Defaults to smind.desktop.xkb.layouts.
      '';
    };

    smind.desktop.gnome.xkb.options = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = config.smind.desktop.xkb.options;
      example = [ "grp:alt_shift_toggle" "caps:escape" ];
      description = ''
        XKB options for GNOME (e.g. layout toggle, caps behavior).
        Defaults to smind.desktop.xkb.options.
      '';
    };

    smind.desktop.gnome.mouse.acceleration = lib.mkOption {
      type = lib.types.numbers.between (-1.0) 1.0;
      default = config.smind.desktop.mouse.acceleration;
      example = 0.2;
      description = ''
        Mouse pointer acceleration/speed for GNOME.
        Defaults to smind.desktop.mouse.acceleration.
      '';
    };

    smind.desktop.gnome.mouse.accelProfile = lib.mkOption {
      type = lib.types.enum [ "default" "flat" "adaptive" ];
      default = config.smind.desktop.mouse.accelProfile;
      example = "adaptive";
      description = ''
        Mouse acceleration profile for GNOME.
        Defaults to smind.desktop.mouse.accelProfile.
      '';
    };

    smind.desktop.gnome.mouse.naturalScroll = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.desktop.mouse.naturalScroll;
      description = ''
        Enable natural scrolling for mouse in GNOME.
        Defaults to smind.desktop.mouse.naturalScroll.
      '';
    };
  };

  # display settings are being controlled over dbus (org.gnome.Mutter.DisplayConfig), not dconf

  config = lib.mkIf config.smind.desktop.gnome.enable {
    programs.dconf = {
      enable = true;

      profiles.user.databases = [
        {
          lockAll = true; # prevents overriding
          settings = lib.mkMerge ([
            {
              "org/gnome/desktop/wm/preferences" = {
                # button-layout = ":minimize,maximize,close";
                button-layout = "close,minimize,maximize:";
                num-workspaces = lib.gvariant.mkInt32 1;
              };
              "org/gnome/mutter/wayland" = {
                #xwayland-allow-grabs = true;
                #xwayland-grab-access-rules=['parsecd']
              };
              "org/gnome/desktop/interface" = {
                gtk-theme = "adw-gtk3-dark";
                document-font-name = "Noto Sans 11";
                monospace-font-name = "Hack Nerd Font Mono 12";
                cursor-theme = "Adwaita";
                cursor-size = lib.gvariant.mkInt32 36;
                font-antialiasing = "rgba";
                clock-show-weekday = true;
                color-scheme = "prefer-dark";
                enable-hot-corners = config.smind.desktop.gnome.hot-corners.enable;
                show-battery-percentage = true;
              };
              "org/gnome/mutter" = {
                dynamic-workspaces = false;
                edge-tiling = true;
                overlay-key = "";
                #workspaces-only-on-primary = true;
                experimental-features =
                  lib.optionals config.smind.desktop.gnome.fractional-scaling.enable [
                    "scale-monitor-framebuffer"
                    "xwayland-native-scaling"
                  ]
                  ++ lib.optionals config.smind.desktop.gnome.vrr.enable [
                    "variable-refresh-rate"
                  ];
              };
              "org/gnome/shell" = {
                "remember-mount-password" = true;
                "always-show-log-out" = true;
              };
              "org/gnome/desktop/notifications" = {
                show-in-lock-screen = false;
              };
              "org/gnome/desktop/peripherals/mouse" = {
                speed = lib.gvariant.mkDouble config.smind.desktop.gnome.mouse.acceleration;
                accel-profile = config.smind.desktop.gnome.mouse.accelProfile;
                natural-scroll = config.smind.desktop.gnome.mouse.naturalScroll;
              };
            }
          ] ++ lib.optional (config.smind.desktop.gnome.xkb.layouts != [ ]) {
            "org/gnome/desktop/input-sources" =
              let xkb = config.smind.desktop.gnome.xkb;
              in {
                # Layouts already in GNOME's "layout+variant" format
                sources = map (layout: lib.gvariant.mkTuple [ "xkb" layout ]) xkb.layouts;
                per-window = true;
                xkb-options = xkb.options;
              };
          } ++ lib.optional config.smind.desktop.gnome.sticky-keys.enable {
            "org/gnome/desktop/a11y/keyboard" = {
              "stickykeys-enable" = true;
              "stickykeys-modifier-beep" = true;
            };
          } ++ [{
            # Configure gsd-power auto-suspend
            "org/gnome/settings-daemon/plugins/power" = {
              sleep-inactive-ac-type = config.smind.desktop.gnome.auto-suspend.onAC;
              sleep-inactive-battery-type = config.smind.desktop.gnome.auto-suspend.onBattery;
              sleep-inactive-ac-timeout = lib.gvariant.mkInt32 config.smind.desktop.gnome.auto-suspend.timeoutAC;
              sleep-inactive-battery-timeout = lib.gvariant.mkInt32 config.smind.desktop.gnome.auto-suspend.timeoutBattery;
            } // lib.optionalAttrs (config.smind.power-management.powerButton != null) {
              # Let logind handle power button (polkit rule denies gsd-media-keys inhibitor)
              power-button-action = "nothing";
            };
          }]);
        }
      ];
    };

    environment.sessionVariables = {
      # GTK_THEME breaks libadwaita apps (Nautilus, Settings) - causes missing paddings
      # Dark theme is handled by color-scheme = "prefer-dark" in dconf instead
      # See: https://discourse.gnome.org/t/why-gtk-theme-env-breaks-adwaita-applications/16016

      #QT_QPA_PLATFORMTHEME = "gnome"; # this breaks Telegram systray icon
      QT_QPA_PLATFORMTHEME = "qgnomeplatform"; # qt.platformTheme is broken, this fixes it

      QT_AUTO_SCREEN_SCALE_FACTOR = "1";
      QT_ENABLE_HIGHDPI_SCALING = "1";
      QT_QPA_PLATFORM = "wayland";

      # Electron apps: use native Wayland instead of XWayland
      ELECTRON_OZONE_PLATFORM_HINT = "wayland";

      GNOME_SHELL_SLOWDOWN_FACTOR = "0.4";
    };

    # Keyring and SSH agent via shared module
    # Note: SSH keys must have corresponding .pub to be recognised by keychain
    # ( ssh-keygen -y -f ~/.ssh/id_ed25519 > ~/.ssh/id_ed25519.pub )
    # See: https://github.com/NixOS/nixpkgs/issues/372802
    smind.security.keyring = {
      enable = true;
      backend = "gnome-keyring";
      sshAgent = "gcr";
      displayManagers = [ "login" "lightdm" "greetd" "gdm" "gdm-password" "gdm-fingerprint" "gdm-autologin" ];
    };

    programs.ssh = {
      # https://wiki.nixos.org/wiki/SSH_public_key_authentication
      startAgent = false;
      enableAskPassword = true;
    };

    security.polkit.enable = true;

    qt =
      {
        enable = true;
        #platformTheme = "qgnomeplatform"; # cannot be assigned, nixpkgs bug
        #platformTheme = "gnome"; # this breaks Telegram systray icon
        platformTheme = null;
        style = "adwaita-dark";
      };

    # https://github.com/NixOS/nixpkgs/issues/33277#issuecomment-639281657
    # https://github.com/NixOS/nixpkgs/issues/114514
    services.desktopManager.gnome = {
      enable = true;
      # extraGSettingsOverridePackages = [ pkgs.mutter ];
      # extraGSettingsOverrides = ''
      #   [org.gnome.mutter]
      #   experimental-features=['scale-monitor-framebuffer', 'xwayland-native-scaling']
      #   [org.gnome.mutter.wayland]
      #   xwayland-allow-grabs=true
      #   xwayland-grab-access-rules=['parsecd']
      # '';
    };

    xdg = {
      portal = {
        enable = true;
        # xdgOpenUsePortal = true;
        # configPackages = [ pkgs.gnome-session ];
        # extraPortals = with pkgs;
        #   [
        #     xdg-desktop-portal-gtk
        #     # kdePackages.xdg-desktop-portal-kde
        #     # xdg-dnesktop-portal-gnome
        #     # lxqt.xdg-desktop-portal-lxqt
        #   ];
      };
    };

    services.gvfs.enable = true;

    services.udev.packages = [ pkgs.gnome-settings-daemon ];

    # Display manager (GDM) configuration handled by smind.display-manager module

    # PAM keyring integration handled by smind.security.keyring module

    environment.systemPackages =
      (with pkgs; [
        adw-gtk3
        dconf-editor
        gnome-firmware
        eog
        pix
        file-roller
        # gnome-remote-desktop
      ]);


    # systemd.services.gnome-remote-desktop = {
    #   wantedBy = [ "graphical.target" ];
    # };

    # Suspend/hibernate quirks (targets, FREEZE workaround, GNOME idle reset) handled by power-suspend-quirks module

    services.gnome = {
      gnome-settings-daemon.enable = true;
      core-apps.enable = true;
      core-os-services.enable = true;
      core-shell.enable = true;
      core-developer-tools.enable = true;
      sushi.enable = true;
      gnome-remote-desktop.enable = true;
      # gnome-keyring and gcr-ssh-agent handled by smind.security.keyring module
    };

    programs.gnome-terminal.enable = true;
    programs.gnome-disks.enable = true;
    # programs.file-roller.enable = true;

    environment.gnome.excludePackages = with pkgs; [
      orca # text to speech
      epiphany
      gnome-text-editor
      gnome-calculator
      gnome-characters
      gnome-clocks
      gnome-console
      # gnome-font-viewer
      gnome-logs
      gnome-maps
      gnome-music
      totem
      yelp
      gnome-tour
      gnome-user-docs
      simple-scan
      geary
      gnome-terminal
    ];
  };
}
