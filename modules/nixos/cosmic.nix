{ config, lib, pkgs, ... }:

{
  options = {
    smind.desktop.cosmic.enable = lib.mkEnableOption "COSMIC desktop environment";
    smind.desktop.cosmic.dconf.profile = lib.mkOption {
      type = lib.types.str;
      default = "cosmic";
      description = "Dconf profile name for COSMIC session. (`cosmic` instead of `user` by default to not conflict with GNOME settings)";
    };
  };

  config = lib.mkIf config.smind.desktop.cosmic.enable {
    programs.dconf = {
      enable = true;
      profiles.${config.smind.desktop.cosmic.dconf.profile}.databases = [
        {
          lockAll = false;
          settings = { };
        }
      ];
    };

    # Enable kanata for Mac-style keyboard shortcuts (same as GNOME)
    smind.keyboard.super-remap.enable = lib.mkDefault true;
    # FIXME: temporarily disabled — cosmic-settings-daemon 1.0.8 fails to build
    # (duplicate dbus-settings-bindings source in Cargo.lock)
    # services.desktopManager.cosmic.enable = true;

    environment.cosmic.excludePackages = with pkgs; [
      orca
    ];

    smind.desktop.wayland.session-variables.enable = true;

    # SSH_AUTH_SOCK override for GCR agent handled by smind.security.keyring module

    security.polkit.enable = true;

    # Polkit authentication agent - cosmic-osd should handle this but has NixOS issues
    # Using polkit_gnome as a reliable fallback for apps like virt-manager
    # Only start in COSMIC sessions - GNOME Shell has its own built-in polkit agent
    systemd.user.services.polkit-gnome-authentication-agent-cosmic = {
      description = "polkit-gnome-authentication-agent-cosmic";
      wantedBy = [ "graphical-session.target" ];
      wants = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        ExecCondition = ''/bin/sh -c '[ "$XDG_CURRENT_DESKTOP" = "COSMIC" ]' '';
        ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
        Restart = "on-failure";
        RestartSec = 1;
        TimeoutStopSec = 10;
      };
    };

    # Keyring and SSH agent via shared module
    # Include GDM PAM services for when COSMIC is selected from GDM session picker
    smind.security.keyring = {
      enable = true;
      backend = "gnome-keyring";
      # mkDefault so maintenance-only COSMIC hosts can opt out of gcr-ssh.
      sshAgent = lib.mkDefault "gcr";
      displayManagers = [ "login" "cosmic-greeter" "greetd" "gdm" "gdm-password" "gdm-fingerprint" "gdm-autologin" ];
    };

    xdg.portal.enable = true;

    services.gvfs.enable = true;

    environment.systemPackages = with pkgs; [
      cosmic-files
      cosmic-edit
      cosmic-term
      cosmic-screenshot
      polkit_gnome
      # seahorse and gcr added by smind.security.keyring module
    ];
  };
}
