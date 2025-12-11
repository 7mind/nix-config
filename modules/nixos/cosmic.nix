{ config, lib, pkgs, ... }:

{
  options = {
    smind.desktop.cosmic.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
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
    ];
  };
}
