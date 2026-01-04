{ config, lib, pkgs, cfg-meta, ... }:

let
  hibernateCfg = config.smind.desktop.gnome.hibernate;
  adaptiveBrightnessCfg = config.smind.desktop.gnome.adaptive-brightness;

  # Patch extensions to support current GNOME shell version
  patchGnomeExtension = ext: ext.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ pkgs.jq ];
    postPatch = (old.postPatch or "") + ''
      jq '.["shell-version"] += ["${lib.versions.major pkgs.gnome-shell.version}"]' metadata.json > tmp.json && mv tmp.json metadata.json
    '';
  });

  hibernateExtensionPatched = patchGnomeExtension pkgs.gnomeExtensions.hibernate-status-button;
in
{
  options = {
    smind.desktop.gnome.adaptive-brightness.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable adaptive brightness extension (requires ambient light sensor)";
    };
  };

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
        vicinae
        # tray-icons-reloaded
      ])
    ++ lib.optional hibernateCfg.enable hibernateExtensionPatched
    ++ lib.optional adaptiveBrightnessCfg.enable pkgs.gnomeExtensions.adaptive-brightness;

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
                gnomeExtensions.vicinae.extensionUuid
                gnome-shortcut-inhibitor.extensionUuid
                # pkgs.gnomeExtensions.tray-icons-reloaded.extensionUuid
              ] ++ lib.optional hibernateCfg.enable hibernateExtensionPatched.extensionUuid
                ++ lib.optional adaptiveBrightnessCfg.enable pkgs.gnomeExtensions.adaptive-brightness.extensionUuid;
            };

          };
        }
      ];
    };

  };
}
