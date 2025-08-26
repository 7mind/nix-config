{ config, lib, pkgs, cfg-meta, ... }:

{
  options = { };

  config = lib.mkIf config.smind.desktop.gnome.enable {

    environment.systemPackages = with pkgs; [
      # This is a dirty fix for annoying "allow inhibit shortcuts?" popups
      # https://discourse.gnome.org/t/virtual-machine-manager-wants-to-inhibit-shortcuts/26017/8
      # https://unix.stackexchange.com/questions/417670/virtual-machine-manager-wants-to-inhibit-shortcuts-again-and-again-on-waylan
      # https://askubuntu.com/questions/1488341/how-do-i-inhibit-shortcuts-for-virtual-machines
      # https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.impl.portal.PermissionStore.html
      gnome-shortcut-inhibitor
    ] ++ (with pkgs.gnomeExtensions;
      [
        appindicator
        gsconnect
        native-window-placement
        caffeine
        # tray-icons-reloaded
      ]);

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
                gnomeExtensions.gsconnect.extensionUuid
                gnomeExtensions.native-window-placement.extensionUuid
                gnomeExtensions.caffeine.extensionUuid
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
