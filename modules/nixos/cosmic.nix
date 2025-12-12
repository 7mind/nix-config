{ config, lib, pkgs, ... }:

{
  options = {
    smind.desktop.cosmic.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable COSMIC desktop environment";
    };
  };

  config = lib.mkIf config.smind.desktop.cosmic.enable {
    services.desktopManager.cosmic.enable = true;

    environment.cosmic.excludePackages = with pkgs; [
      orca
    ];

    environment.sessionVariables = {
      QT_AUTO_SCREEN_SCALE_FACTOR = "1";
      QT_ENABLE_HIGHDPI_SCALING = "1";
      QT_QPA_PLATFORM = "wayland";
    };

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

    xdg.portal.enable = true;

    services.gvfs.enable = true;

    systemd.targets.sleep.enable = false;
    systemd.targets.suspend.enable = false;
    systemd.targets.hibernate.enable = false;
    systemd.targets.hybrid-sleep.enable = false;

    environment.systemPackages = with pkgs; [
      cosmic-files
      cosmic-edit
      cosmic-term
      cosmic-screenshot
      polkit_gnome
    ];
  };
}
