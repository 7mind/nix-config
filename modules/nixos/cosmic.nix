{ config, lib, pkgs, ... }:

{
  options = {
    smind.desktop.cosmic.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable COSMIC desktop environment";
    };

    smind.desktop.cosmic.hibernate.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.isLaptop;
      description = "Enable hibernate/suspend support in COSMIC";
    };
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

    # Set SSH_AUTH_SOCK for gcr-ssh-agent (same pattern as Budgie/Cinnamon/MATE)
    # The gcr-ssh-agent.socket sets this via systemd, but shells may not inherit it
    environment.extraInit = lib.mkIf config.services.gnome.gcr-ssh-agent.enable ''
      if [ -z "$SSH_AUTH_SOCK" ] || [ ! -S "$SSH_AUTH_SOCK" ]; then
        export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/gcr/ssh"
      fi
    '';

    security.polkit.enable = true;

    # Polkit authentication agent - cosmic-osd should handle this but has NixOS issues
    # Using polkit_gnome as a reliable fallback for apps like virt-manager
    systemd.user.services.polkit-gnome-authentication-agent-1 = {
      description = "polkit-gnome-authentication-agent-1";
      wantedBy = [ "graphical-session.target" ];
      wants = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
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
      displayManagers = [ "login" "greetd" "cosmic-greeter" "gdm" "gdm-password" "gdm-fingerprint" "gdm-autologin" ];
    };

    xdg.portal.enable = true;

    services.gvfs.enable = true;

    systemd.targets.sleep.enable = config.smind.desktop.cosmic.hibernate.enable;
    systemd.targets.suspend.enable = config.smind.desktop.cosmic.hibernate.enable;
    systemd.targets.hibernate.enable = config.smind.desktop.cosmic.hibernate.enable;
    systemd.targets.hybrid-sleep.enable = config.smind.desktop.cosmic.hibernate.enable;

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
