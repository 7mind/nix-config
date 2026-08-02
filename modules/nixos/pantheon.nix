{ config, lib, pkgs, ... }:

{
  options.smind.desktop.pantheon.enable = lib.mkEnableOption "Pantheon desktop environment";

  config = lib.mkIf config.smind.desktop.pantheon.enable {
    assertions = [
      {
        assertion = !config.smind.desktop.gnome.enable;
        message = "Pantheon and GNOME cannot be enabled together";
      }
    ];

    services.desktopManager.pantheon.enable = true;
    services.pantheon.apps.enable = true;

    # AppCenter and Sideload require Flatpak; the remaining non-default apps
    # complete the application set exposed by pkgs.pantheon.
    services.flatpak.enable = true;
    environment.systemPackages = with pkgs.pantheon; [
      elementary-feedback
      elementary-iconbrowser
    ];

    smind.desktop.wayland.session-variables.enable = true;

    smind.security.keyring = {
      enable = true;
      backend = "gnome-keyring";
      sshAgent = "gcr";
      displayManagers = [ "login" "lightdm" ];
    };
  };
}
