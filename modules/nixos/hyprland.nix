{ config, lib, pkgs, ... }:

{
  options = {
    smind.desktop.hyprland.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Hyprland compositor";
    };

    smind.desktop.hyprland.uwsm.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable UWSM (Universal Wayland Session Manager) for Hyprland.
        UWSM provides better session management but requires dbus-broker,
        which cannot be switched on a live system (requires reboot).
      '';
    };

    smind.desktop.hyprland.xkb.layouts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = config.smind.desktop.xkb.layouts;
      example = [ "us+dvorak" "de" "fr+azerty" ];
      description = ''
        XKB keyboard layouts for Hyprland in "layout+variant" format.
        Defaults to smind.desktop.xkb.layouts.
      '';
    };

    smind.desktop.hyprland.xkb.options = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = config.smind.desktop.xkb.options;
      example = [ "grp:alt_shift_toggle" "caps:escape" ];
      description = ''
        XKB options for Hyprland (e.g. layout toggle, caps behavior).
        Defaults to smind.desktop.xkb.options.
      '';
    };
  };

  config = lib.mkIf config.smind.desktop.hyprland.enable {
    programs.hyprland = {
      enable = true;
      withUWSM = config.smind.desktop.hyprland.uwsm.enable;
    };

    smind.desktop.wayland.session-variables.enable = true;

    smind.security.keyring = {
      enable = true;
      backend = "gnome-keyring";
      sshAgent = "gcr";
      displayManagers = [ "login" "greetd" "gdm" "gdm-password" "gdm-fingerprint" "gdm-autologin" ];
    };

    security.polkit.enable = true;

    # Polkit authentication agent
    systemd.user.services.polkit-gnome-authentication-agent-hyprland = {
      description = "polkit-gnome-authentication-agent-hyprland";
      wantedBy = [ "graphical-session.target" ];
      wants = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        ExecCondition = ''/bin/sh -c '[ "$XDG_CURRENT_DESKTOP" = "Hyprland" ]' '';
        ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
        Restart = "on-failure";
        RestartSec = 1;
        TimeoutStopSec = 10;
      };
    };

    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-hyprland ];
    };

    services.gvfs.enable = true;

    environment.systemPackages = with pkgs; [
      hyprpaper
      hyprlock
      hypridle
      hyprpicker
      waybar
      wofi
      mako
      grim
      slurp
      wl-clipboard
      cliphist
      polkit_gnome
      networkmanagerapplet
      pavucontrol
      brightnessctl
      playerctl
    ];
  };
}
