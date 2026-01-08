{ config, lib, pkgs, cfg-meta, ... }:

{
  options = {
    smind.desktop.gnome.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable GNOME desktop environment with GDM";
    };

    smind.desktop.gnome.suspend.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.isLaptop;
      description = "Enable suspend support";
    };

    smind.desktop.gnome.hibernate.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.isLaptop && !config.smind.zfs.enable; # hibernate breaks ZFS
      description = "Enable hibernate and hybrid-sleep support with GNOME hibernate-status-button extension";
    };

    smind.desktop.gnome.auto-suspend.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.isLaptop;
      description = "Enable automatic suspend on idle (typically for laptops)";
    };

    smind.desktop.gnome.auto-suspend.useLogind = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Use systemd-logind for idle suspend instead of GNOME's gsd-power.
        This bypasses gsd-power's buggy idle timer that can cause suspend loops after resume.
        See: https://github.com/NixOS/nixpkgs/issues/336723
      '';
    };

    smind.desktop.gnome.auto-suspend.idleActionSec = lib.mkOption {
      type = lib.types.str;
      default = "15min";
      example = "20min";
      description = "Idle time before suspend when using logind (useLogind = true)";
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

    smind.desktop.gnome.keyboard-layouts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "us+mac" "ru" ];
      example = [ "us" "de" "fr" ];
      description = "XKB keyboard layouts to configure (e.g. 'us+mac', 'ru', 'de')";
    };

    smind.desktop.gnome.xkb-options = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "grp:caps_toggle" ];
      example = [ "grp:alt_shift_toggle" "caps:escape" ];
      description = "XKB options (e.g. layout toggle, caps behavior)";
    };

    smind.desktop.gnome.switch-input-source-keybinding = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "<Ctrl><Alt><Super>space" ];
      description = "Keybinding(s) for switching to next input source (in addition to xkb-options)";
    };

    smind.desktop.gnome.sticky-keys.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable sticky keys with GNOME Shell keyboard-modifiers-status extension";
    };

    smind.desktop.gnome.gdm.monitors-xml = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./monitors.xml";
      description = "Path to monitors.xml for GDM login screen display configuration";
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
                enable-hot-corners = false;
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
            }
          ] ++ lib.optional (config.smind.desktop.gnome.keyboard-layouts != [ ]) {
            "org/gnome/desktop/input-sources" = {
              sources = map (layout: lib.gvariant.mkTuple [ "xkb" layout ]) config.smind.desktop.gnome.keyboard-layouts;
              per-window = true;
              xkb-options = config.smind.desktop.gnome.xkb-options;
            };
          } ++ lib.optional config.smind.desktop.gnome.sticky-keys.enable {
            "org/gnome/desktop/a11y/keyboard" = {
              "stickykeys-enable" = true;
              "stickykeys-modifier-beep" = true;
            };
          } ++ lib.optional (!config.smind.desktop.gnome.auto-suspend.enable || config.smind.desktop.gnome.auto-suspend.useLogind) {
            # Disable gsd-power auto-suspend (either fully disabled, or using logind instead)
            "org/gnome/settings-daemon/plugins/power" = {
              sleep-inactive-ac-type = "nothing";
              sleep-inactive-battery-type = "nothing";
            };
          });
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

    #services.xrdp.enable = true;
    #services.xrdp.defaultWindowManager = "${pkgs.icewm}/bin/icewm";
    #networking.firewall.allowedTCPPorts = [ 3389 ];
    #networking.firewall.allowedUDPPorts = [ 3389 ];

    systemd.targets.sleep.enable = lib.mkIf (config.smind.desktop.gnome.suspend.enable || config.smind.desktop.gnome.hibernate.enable) true;
    systemd.targets.suspend.enable = lib.mkIf config.smind.desktop.gnome.suspend.enable true;
    systemd.targets.hibernate.enable = lib.mkIf config.smind.desktop.gnome.hibernate.enable true;
    systemd.targets.hybrid-sleep.enable = lib.mkIf config.smind.desktop.gnome.hibernate.enable true;

    # Workaround: Disable systemd 256+ user session freezing during sleep
    # This feature doesn't work reliably with NVIDIA/AMD drivers and causes suspend failures
    # See: https://github.com/NixOS/nixpkgs/issues/371058
    systemd.services.systemd-suspend.environment.SYSTEMD_SLEEP_FREEZE_USER_SESSIONS = lib.mkIf config.smind.desktop.gnome.suspend.enable "false";
    systemd.services.systemd-hibernate.environment.SYSTEMD_SLEEP_FREEZE_USER_SESSIONS = lib.mkIf config.smind.desktop.gnome.hibernate.enable "false";
    systemd.services.systemd-hybrid-sleep.environment.SYSTEMD_SLEEP_FREEZE_USER_SESSIONS = lib.mkIf config.smind.desktop.gnome.hibernate.enable "false";
    systemd.services.systemd-suspend-then-hibernate.environment.SYSTEMD_SLEEP_FREEZE_USER_SESSIONS = lib.mkIf config.smind.desktop.gnome.hibernate.enable "false";

    # Workaround: Reset GNOME idle state after resume to prevent suspend loop
    # gsd-power doesn't reset its internal idle counter after resume, causing immediate re-suspend
    # Uses system-sleep hook for immediate execution on resume (before gsd-power can react)
    # See: https://github.com/NixOS/nixpkgs/issues/336723
    # See: https://gitlab.gnome.org/World/Phosh/phosh/-/merge_requests/1016
    # Use logind for idle suspend instead of gsd-power (optional, disabled by default)
    # This bypasses gsd-power's buggy idle timer entirely
    services.logind.settings.Login = lib.mkIf config.smind.desktop.gnome.auto-suspend.useLogind {
      IdleAction = "suspend";
      IdleActionSec = config.smind.desktop.gnome.auto-suspend.idleActionSec;
    };

    powerManagement.powerDownCommands = lib.mkIf (config.smind.desktop.gnome.suspend.enable || config.smind.desktop.gnome.hibernate.enable) "";
    powerManagement.resumeCommands = lib.mkIf (config.smind.desktop.gnome.suspend.enable || config.smind.desktop.gnome.hibernate.enable) ''
      # Reset idle hint for all logind sessions immediately on resume
      ${pkgs.systemd}/bin/loginctl list-sessions --no-legend | while read -r session rest; do
        ${pkgs.systemd}/bin/loginctl set-idle-hint "$session" no 2>/dev/null || true
      done

      # Reset GNOME session presence to "available" (0) for all graphical users
      # This signals gnome-session that user is active, resetting gsd-power's idle timer
      for uid in $(${pkgs.systemd}/bin/loginctl list-users --no-legend | ${pkgs.gawk}/bin/awk '{print $1}'); do
        user=$(${pkgs.coreutils}/bin/id -nu "$uid" 2>/dev/null) || continue
        runtime_dir="/run/user/$uid"
        [ -S "$runtime_dir/bus" ] || continue

        ${pkgs.sudo}/bin/sudo -u "$user" \
          DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
          ${pkgs.dbus}/bin/dbus-send --session --type=method_call \
            --dest=org.gnome.SessionManager \
            /org/gnome/SessionManager/Presence \
            org.gnome.SessionManager.Presence.SetStatus \
            uint32:0 2>/dev/null || true
      done
    '';

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
