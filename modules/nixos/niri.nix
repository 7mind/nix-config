{ config, lib, pkgs, ... }:

{
  options = {
    smind.desktop.niri.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Niri compositor";
    };

    smind.desktop.niri.xkb.layouts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = config.smind.desktop.xkb.layouts;
      example = [ "us+dvorak" "de" "fr+azerty" ];
      description = ''
        XKB keyboard layouts for Niri in "layout+variant" format.
        Defaults to smind.desktop.xkb.layouts.
      '';
    };

    smind.desktop.niri.xkb.options = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = config.smind.desktop.xkb.options;
      example = [ "grp:alt_shift_toggle" "caps:escape" ];
      description = ''
        XKB options for Niri (e.g. layout toggle, caps behavior).
        Defaults to smind.desktop.xkb.options.
      '';
    };
  };

  config = lib.mkIf config.smind.desktop.niri.enable {
    programs.niri = {
      enable = true;
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
    systemd.user.services.polkit-gnome-authentication-agent-niri = {
      description = "polkit-gnome-authentication-agent-niri";
      wantedBy = [ "graphical-session.target" ];
      wants = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        ExecCondition = ''/bin/sh -c '[ "$XDG_CURRENT_DESKTOP" = "niri" ]' '';
        ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-niri";
        Restart = "on-failure";
        RestartSec = 1;
        TimeoutStopSec = 10;
      };
    };

    xdg.portal = {
      enable = true;
      extraPortals = [
        pkgs.xdg-desktop-portal-gnome
        pkgs.xdg-desktop-portal-gtk
      ];
    };

    services.gvfs.enable = true;

    environment.systemPackages = with pkgs; [
      swaylock
      swayidle
      swaybg
      waybar
      fuzzel
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
