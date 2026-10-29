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
      default = 2 * 60 * 60;
      description = "Idle timeout in seconds before action on AC power";
    };

    smind.desktop.gnome.auto-suspend.timeoutBattery = lib.mkOption {
      type = lib.types.int;
      default = 15 * 60;
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

    smind.desktop.gnome.ghostty-toggle.enable = lib.mkEnableOption "F5 keybinding to show/spawn Ghostty terminal";

    smind.desktop.gnome.ghostty-toggle.key = lib.mkOption {
      type = lib.types.str;
      default = "F5";
      example = "Return";
      description = "Key to bind for Ghostty toggle (without modifier)";
    };

    smind.desktop.gnome.ghostty-toggle.use-modifier = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to require the hotkey-modifier (Ctrl/Super) for the Ghostty toggle";
    };

    smind.desktop.gnome.interface.iconTheme = lib.mkOption {
      type = lib.types.str;
      default = "Adwaita";
      description = "GNOME icon theme name.";
    };

    smind.desktop.gnome.interface.cursorTheme = lib.mkOption {
      type = lib.types.str;
      default = "Adwaita";
      description = "GNOME cursor theme name.";
    };

    smind.desktop.gnome.wm.buttonLayout = lib.mkOption {
      type = lib.types.str;
      default = "close,minimize,maximize:";
      description = "GNOME window button layout.";
    };

    smind.desktop.gnome.single-workspace = lib.mkEnableOption "a single GNOME workspace" // { default = true; };

    smind.desktop.gnome.gvfs.disableMtp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Disable gvfs MTP volume monitor. Prevents gvfsd-mtp from spawning,
        which can cause localsearch hangs and nautilus freezes when a phone
        is connected via USB in charging/locked mode.
      '';
    };

    smind.desktop.gnome.localsearch.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable LocalSearch (Tracker) file indexer. Provides file content search
        in Nautilus. Disable if localsearch causes hangs (e.g. due to
        interactions with gvfsd-mtp or network volume monitors).
      '';
    };

    smind.desktop.gnome.gdm.monitors-xml = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./monitors.xml";
      description = "Path to monitors.xml for GDM login screen display configuration";
    };

    smind.desktop.gnome.xkb.per-window = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Use a separate input source for each window. Set to false to use the same source for all windows.";
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
        Initial mouse pointer acceleration/speed for GNOME, overridable by users.
        Defaults to smind.desktop.mouse.acceleration.
      '';
    };

    smind.desktop.gnome.mouse.accelProfile = lib.mkOption {
      type = lib.types.enum [ "default" "flat" "adaptive" ];
      default = config.smind.desktop.mouse.accelProfile;
      example = "adaptive";
      description = ''
        Initial mouse acceleration profile for GNOME, overridable by users.
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

    smind.desktop.gnome.touchpad.disableWhileTyping = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Disable touchpad input while typing in GNOME.";
    };

    smind.desktop.gnome.dconf.profile = lib.mkOption {
      type = lib.types.str;
      default = "user";
      description = "Dconf profile name for GNOME session.";
    };

    smind.desktop.gnome.minimal.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Exclude unnecessary GNOMOE apps.";
    };
  };

  # display settings are being controlled over dbus (org.gnome.Mutter.DisplayConfig), not dconf

  config = lib.mkIf config.smind.desktop.gnome.enable {
    programs.dconf = {
      enable = true;

      profiles.${config.smind.desktop.gnome.dconf.profile}.databases = [
        {
          lockAll = true;
          settings = import ../../lib/gnome-desktop-settings.nix {
            inherit lib;
            gnome = config.smind.desktop.gnome;
            powerButton = config.smind.power-management.powerButton;
          };
        }
        {
          settings."org/gnome/desktop/peripherals/mouse" = {
            speed = lib.gvariant.mkDouble config.smind.desktop.gnome.mouse.acceleration;
            accel-profile = config.smind.desktop.gnome.mouse.accelProfile;
          };
        }
      ];
    };

    smind.desktop.wayland.session-variables.enable = true;

    environment.sessionVariables = {
      # GTK_THEME breaks libadwaita apps (Nautilus, Settings) - causes missing paddings
      # Dark theme is handled by color-scheme = "prefer-dark" in dconf instead
      # See: https://discourse.gnome.org/t/why-gtk-theme-env-breaks-adwaita-applications/16016

      QT_QPA_PLATFORMTHEME = "qgnomeplatform"; # qt.platformTheme is broken, this fixes it

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
        platformTheme = null;
        style = "adwaita-dark";
      };

    services.desktopManager.gnome = {
      enable = true;
    };

    xdg = {
      portal = {
        enable = true;
      };
    };

    services.gvfs.enable = true;
    # Base off pkgs.gnome.gvfs (gnomeSupport=true) — the default services.gvfs.package.
    # Starting from bare pkgs.gvfs would pick gnomeSupport=false, drop libsecret/gcr/goa
    # and apply -Dkeyring=false, which makes gvfsd-smb's g_vfs_keyring_is_available()
    # return FALSE: no Remember UI, no keyring lookup, no keyring save for SMB shares.
    services.gvfs.package = lib.mkIf config.smind.desktop.gnome.gvfs.disableMtp
      (pkgs.gnome.gvfs.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + ''
          rm -f $out/share/gvfs/remote-volume-monitors/mtp.monitor
          rm -f $out/share/dbus-1/services/org.gtk.vfs.MTPVolumeMonitor.service
          rm -f $out/lib/systemd/user/gvfs-mtp-volume-monitor.service
        '';
      }));

    services.udev.packages = [ pkgs.gnome-settings-daemon ];

    environment.systemPackages =
      (with pkgs; [
        adw-gtk3
        dconf-editor
        gnome-firmware
        eog
        pix
        file-roller
        gnome-connections
        gnome-randr
      ]);

    services.gnome = {
      gnome-settings-daemon.enable = true;
      core-apps.enable = true;
      core-os-services.enable = true;
      core-shell.enable = true;
      core-developer-tools.enable = true;
      sushi.enable = true;
      localsearch.enable = config.smind.desktop.gnome.localsearch.enable;
      gnome-remote-desktop.enable = true;
    };

    programs.gnome-terminal.enable = true;
    programs.gnome-disks.enable = true;

    environment.gnome.excludePackages =
      [ pkgs.orca ] ++
      (lib.optionals config.smind.desktop.gnome.minimal.enable (with pkgs; [
        epiphany # text to speech
        gnome-text-editor
        gnome-calculator
        gnome-characters
        gnome-clocks
        gnome-console
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
      ]));
  };
}
