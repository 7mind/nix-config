{ config, lib, pkgs, ... }:

{
  options = {
    smind.desktop.cosmic.enable = lib.mkEnableOption "COSMIC desktop environment";
  };

  config = lib.mkIf config.smind.desktop.cosmic.enable {
    # Enable kanata for Mac-style keyboard shortcuts (same as GNOME)
    smind.keyboard.super-remap.enable = lib.mkDefault true;
    services.desktopManager.cosmic.enable = true;

    environment.cosmic.excludePackages = with pkgs; [
      orca
    ];

    environment.sessionVariables = {
      QT_AUTO_SCREEN_SCALE_FACTOR = "1";
      QT_ENABLE_HIGHDPI_SCALING = "1";
      QT_QPA_PLATFORM = "wayland";
    };

    # Set SSH_AUTH_SOCK for gcr-ssh-agent in COSMIC sessions
    # Something sets SSH_AUTH_SOCK to keyring/ssh before shells start,
    # so we override it in interactive shells (only for COSMIC)
    programs.zsh.interactiveShellInit = lib.mkIf config.services.gnome.gcr-ssh-agent.enable ''
      if [[ "$XDG_CURRENT_DESKTOP" == "COSMIC" ]]; then
        export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/gcr/ssh"
      fi
    '';
    programs.bash.interactiveShellInit = lib.mkIf config.services.gnome.gcr-ssh-agent.enable ''
      if [[ "$XDG_CURRENT_DESKTOP" == "COSMIC" ]]; then
        export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/gcr/ssh"
      fi
    '';

    security.polkit.enable = true;

    # Polkit authentication agent - cosmic-osd should handle this but has NixOS issues
    # Using polkit_gnome as a reliable fallback for apps like virt-manager
    # Only start in COSMIC sessions - GNOME Shell has its own built-in polkit agent
    systemd.user.services.polkit-gnome-authentication-agent-1 = {
      description = "polkit-gnome-authentication-agent-1";
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
      sshAgent = "gcr";
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
