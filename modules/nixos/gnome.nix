{ config, lib, pkgs, cfg-meta, ... }:

{
  options = {
    smind.desktop.gnome.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable GNOME desktop environment with GDM";
    };
  };

  # display settings are being controlled over dbus (org.gnome.Mutter.DisplayConfig), not dconf

  config = lib.mkIf config.smind.desktop.gnome.enable {
    programs.dconf = {
      enable = true;
      profiles.user.databases = [
        {
          lockAll = true; # prevents overriding
          settings = {
            "org/gnome/desktop/wm/preferences" = {
              # button-layout = ":minimize,maximize,close";
              button-layout = "close,minimize,maximize:";
            };
            "org/gnome/mutter/wayland" = {
              #xwayland-allow-grabs = true;
              #xwayland-grab-access-rules=['parsecd']
            };
            "org/gnome/desktop/interface" = {
              #gtk-theme = "Breeze";
              #cursor-theme = "breeze_cursors";
              #icon-theme = "breeze-dark";
              document-font-name = "Noto Sans 11";
              monospace-font-name = "Hack Nerd Font Mono 12";
              cursor-size = lib.gvariant.mkInt32 36;
              font-antialising = "rgba";
              clock-show-weekday = true;
              color-scheme = "prefer-dark";
            };
            "org/gnome/mutter" = {
              dynamic-workspaces = false;
              edge-tiling = true;
              overlay-key = "";
              #workspaces-only-on-primary = true;
              experimental-features = [
                "scale-monitor-framebuffer"
                "xwayland-native-scaling"
              ];
            };

            "org/gnome/shell" = {
              "remember-mount-password" = true;
              "always-show-log-out" = true;
            };
          };
        }
      ];
    };

    environment.sessionVariables = {
      GTK_THEME = "Adwaita:dark";

      #QT_QPA_PLATFORMTHEME = "gnome"; # this breaks Telegram systray icon
      QT_QPA_PLATFORMTHEME = "qgnomeplatform"; # qt.platformTheme is broken, this fixes it

      QT_AUTO_SCREEN_SCALE_FACTOR = "1";
      QT_ENABLE_HIGHDPI_SCALING = "1";
      QT_QPA_PLATFORM = "wayland";
    };

    # see https://github.com/NixOS/nixpkgs/issues/372802
    # an SSH key must have corresponding .pub in order to be recognised by keychain ( ssh-keygen -y -f ~/.ssh/id_ed25519 > ~/.ssh/id_ed25519.pub )
    programs.seahorse.enable = true;

    programs.ssh = {
      # https://wiki.nixos.org/wiki/SSH_public_key_authentication
      startAgent = false;
      enableAskPassword = true;

      # ssh ignores SSH_ASKPASS if it detects a TTY, workaround:
      # setsid ssh-add < /dev/null
      #askPassword =
      #  lib.mkForce "${pkgs.seahorse}/libexec/seahorse/ssh-askpass";
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

    services.xserver.enable = true;
    services.displayManager.gdm.enable = true;

    security.pam = {
      services = {
        login.enableGnomeKeyring = true;
        sddm.enableGnomeKeyring = true;
        lightdm.enableGnomeKeyring = true;
        greetd.enableGnomeKeyring = true;
        gdm.enableGnomeKeyring = true;
      };
    };

    programs.kdeconnect =
      {
        enable = true;
        package = pkgs.gnomeExtensions.gsconnect;
      };

    environment.systemPackages =
      (with pkgs; [
        dconf-editor
        seahorse
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

    systemd.targets.sleep.enable = false;
    systemd.targets.suspend.enable = false;
    systemd.targets.hibernate.enable = false;
    systemd.targets.hybrid-sleep.enable = false;

    services.gnome = {
      gnome-settings-daemon.enable = true;
      core-apps.enable = true;
      core-os-services.enable = true;
      core-shell.enable = true;
      core-developer-tools.enable = true;
      sushi.enable = true;
      gnome-remote-desktop.enable = true;
      gnome-keyring.enable = true;
      gcr-ssh-agent.enable = true;
    };

    programs.gnome-terminal.enable = true;
    programs.gnome-disks.enable = true;
    # programs.file-roller.enable = true;

    environment.gnome.excludePackages = with pkgs; [
      orca # text to speech
      epiphany
      gnome-text-editor
      gnome-calculator
      gnome-calendar
      gnome-characters
      gnome-clocks
      gnome-console
      gnome-contacts
      # gnome-font-viewer
      gnome-logs
      gnome-maps
      gnome-music
      gnome-weather
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
