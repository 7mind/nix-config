{ config, lib, pkgs, cfgmeta, ... }:

{
  options = {
    smind.desktop.gnome.minimal-hotkeys = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.desktop.gnome.enable {

    environment.systemPackages = with pkgs; [
      gnome-shortcut-inhibitor
    ];

    programs.dconf = {
      enable = true;
      profiles.user.databases = [
        {
          lockAll = true; # prevents overriding

          settings = {
            "org/gnome/shell" = {
              disable-user-extensions = false;
              enabled-extensions = with pkgs; [
                gnomeExtensions.appindicator.extensionUuid
                gnome-shortcut-inhibitor.extensionUuid
                # pkgs.gnomeExtensions.tray-icons-reloaded.extensionUuid
              ];
            };

          };
        }
      ];
    };
  };
}
