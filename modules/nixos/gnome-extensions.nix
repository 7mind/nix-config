{ config, lib, pkgs, cfg-meta, ... }:

let
  hibernateCfg = config.smind.power-management.hibernate;
  superRemapCfg = config.smind.keyboard.super-remap;
  hasKanataSwitcher = lib.any (keyboardCfg: keyboardCfg."kanata-switcher".enable) (
    lib.attrValues superRemapCfg.kanata.keyboards
  );
  extCfg = config.smind.desktop.gnome.extensions;

  # Patch extensions to support current GNOME shell version
  patchGnomeExtension = ext: ext.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.jq ];
    postPatch = (old.postPatch or "") + ''
      jq '.["shell-version"] += ["${lib.versions.major pkgs.gnome-shell.version}"]' metadata.json > tmp.json && mv tmp.json metadata.json
    '';
  });

  hibernateExtensionPatched = patchGnomeExtension pkgs.gnomeExtensions.hibernate-status-button;
  roundedWindowCornersRebornPatched = patchGnomeExtension pkgs.gnomeExtensions.rounded-window-corners-reborn;

  ghosttyCfg = config.smind.desktop.gnome.ghostty-toggle;

  extensions = with pkgs; [
    # This is a dirty fix for annoying "allow inhibit shortcuts?" popups
    # https://discourse.gnome.org/t/virtual-machine-manager-wants-to-inhibit-shortcuts/26017/8
    # https://unix.stackexchange.com/questions/417670/virtual-machine-manager-wants-to-inhibit-shortcuts-again-and-again-on-waylan
    # https://askubuntu.com/questions/1488341/how-do-i-inhibit-shortcuts-for-virtual-machines
    # https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.impl.portal.PermissionStore.html
    gnome-shortcut-inhibitor
  ]
  ++ lib.optional extCfg.run-or-raise.enable pkgs.gnomeExtensions.run-or-raise
  ++ lib.optional extCfg.appindicator.enable pkgs.gnomeExtensions.appindicator
  ++ lib.optional extCfg.gsconnect.enable pkgs.gnomeExtensions.gsconnect
  ++ lib.optional extCfg.native-window-placement.enable pkgs.gnomeExtensions.native-window-placement
  ++ lib.optional extCfg.caffeine.enable pkgs.gnomeExtensions.caffeine
  ++ lib.optional extCfg.vicinae.enable pkgs.gnomeExtensions.vicinae
  ++ lib.optional extCfg.steal-my-focus-window.enable pkgs.gnomeExtensions.steal-my-focus-window
  ++ lib.optional extCfg.dim-completed-calendar-events.enable pkgs.gnomeExtensions.dim-completed-calendar-events
  ++ lib.optional extCfg.rounded-window-corners-reborn.enable roundedWindowCornersRebornPatched
  ++ lib.optional extCfg.tiling-shell.enable pkgs.gnomeExtensions.tiling-shell
  ++ lib.optional extCfg.open-bar.enable pkgs.gnomeExtensions.open-bar
  ++ lib.optional extCfg.grand-theft-focus.enable pkgs.gnomeExtensions.grand-theft-focus
  ++ lib.optional extCfg.highlight-focus.enable pkgs.gnomeExtensions.highlight-focus
  ++ lib.optional extCfg.tray-icons-reloaded.enable pkgs.gnomeExtensions.tray-icons-reloaded
  ++ lib.optional extCfg.dash-to-dock.enable pkgs.gnomeExtensions.dash-to-dock
  ++ lib.optional extCfg.dash2dock-lite.enable pkgs.gnomeExtensions.dash2dock-lite
  ++ lib.optional extCfg.no-overview.enable pkgs.gnomeExtensions.no-overview
  ++ lib.optional extCfg.touchpad-gesture-customization.enable pkgs.gnome-shell-extension-touchpad-gesture-customization-app-expose
  ++ lib.optional hibernateCfg.enable hibernateExtensionPatched
  ++ lib.optional config.smind.desktop.gnome.sticky-keys.enable gnomeExtensions.keyboard-modifiers-status
  ++ lib.optional hasKanataSwitcher config.services.kanata-switcher.gnomeExtension.package;
in
{
  options = {
    smind.desktop.gnome.allow-local-extensions = lib.mkEnableOption "local installation of GNOME Shell extensions (non-declaratively). When false, extension settings are locked via dconf";

    smind.desktop.gnome.extensions = {
      appindicator.enable = lib.mkEnableOption "AppIndicator/KStatusNotifierItem support for the GNOME Shell" // { default = true; };
      gsconnect.enable = lib.mkEnableOption "GSConnect - KDE Connect implementation for GNOME" // {
        default = config.smind.kdeconnect.selectedBackend == "gsconnect";
      };
      native-window-placement.enable = lib.mkEnableOption "Native window placement extension" // { default = true; };
      caffeine.enable = lib.mkEnableOption "Caffeine - disable screensaver and auto suspend" // { default = true; };
      vicinae.enable = lib.mkEnableOption "Vicinae extension" // { default = true; };
      steal-my-focus-window.enable = lib.mkEnableOption "steal focus for windows that request attention" // { default = true; };
      dim-completed-calendar-events.enable = lib.mkEnableOption "dimming of completed calendar events" // { default = true; };
      rounded-window-corners-reborn.enable = lib.mkEnableOption "rounded-window-corners extension" // { default = false; };
      tiling-shell.enable = lib.mkEnableOption "tiling-shell extension" // { default = false; };
      open-bar.enable = lib.mkEnableOption "open-bar extension" // { default = false; };
      grand-theft-focus.enable = lib.mkEnableOption "grand-theft-focus extension" // { default = false; };
      highlight-focus.enable = lib.mkEnableOption "highlight-focus extension" // { default = false; };
      tray-icons-reloaded.enable = lib.mkEnableOption "tray-icons-reloaded extension" // { default = false; };
      dash-to-dock = {
        enable = lib.mkEnableOption "dash-to-dock extension" // { default = false; };
        unity-like-config = {
          enable = lib.mkEnableOption "unity-like options for dash-to-dock" // { default = true; };
          super-num-hotkeys = lib.mkEnableOption "enable dash-to-dock super-<N> hotkeys";
        };
      };
      dash2dock-lite.enable = lib.mkEnableOption "dash2dock-lite extension" // { default = false; };
      no-overview.enable = lib.mkEnableOption "no-overview extension - skip overview on login" // { default = false; };
      touchpad-gesture-customization = {
        enable = lib.mkEnableOption "Touchpad Gesture Customization — remap touchpad gestures" // {
          default = config.smind.three-finger-drag.enable;
        };
        remap-3-to-4 = lib.mkEnableOption "remap GNOME's 3-finger gestures to 4-finger (frees 3-finger for drag)" // {
          default = config.smind.three-finger-drag.enable;
        };
      };
      run-or-raise.enable = lib.mkEnableOption "run-or-raise extension (D-Bus always enabled)" // { default = ghosttyCfg.enable; };
    };
  };

  config = lib.mkIf config.smind.desktop.gnome.enable {

    environment.systemPackages = extensions;

    # Polkit rules for GNOME extensions
    security.polkit.extraConfig = ''
      // Allow any local session to claim sensors from iio-sensor-proxy (ALS)
      polkit.addRule(function(action, subject) {
        if (action.id == "net.hadess.SensorProxy.claim-sensor") {
          return polkit.Result.YES;
        }
      });
    '';

    programs.dconf = {
      enable = true;
      profiles.${config.smind.desktop.gnome.dconf.profile}.databases = [
        {
          lockAll = !config.smind.desktop.gnome.allow-local-extensions;

          settings = lib.mkMerge ([
            {
              "org/gnome/shell" = {
                disable-user-extensions = false;
                enabled-extensions = map (e: e.extensionUuid) extensions;
              };
            }
          ] ++ lib.optional extCfg.run-or-raise.enable {
            "org/gnome/shell/extensions/run-or-raise" = {
              dbus = true;
            };
          } ++ lib.optional (extCfg.touchpad-gesture-customization.enable && extCfg.touchpad-gesture-customization.remap-3-to-4) {
            # Move GNOME's default 3-finger swipe gestures to 4-finger,
            # freeing 3-finger input for linux-3-finger-drag
            "org/gnome/shell/extensions/touchpad-gesture-customization" = {
              vertical-swipe-3-fingers-gesture = "NONE";
              horizontal-swipe-3-fingers-gesture = "NONE";
              pinch-3-finger-gesture = "NONE";
            };
          } ++ lib.optional (extCfg.dash-to-dock.enable && extCfg.dash-to-dock.unity-like-config.enable) {
            "org/gnome/shell/extensions/dash-to-dock" = {
              dock-position = "LEFT";
              dock-fixed = false; # due to upstream bug, only panel mode works for autohide
              custom-theme-shrink = true;
          #              autohide = true;
          #              intellihide = false;
          #              intellihide-mode = "ALL_WINDOWS";
              hot-keys = extCfg.dash-to-dock.unity-like-config.super-num-hotkeys;
              click-action = "focus-or-appspread";
              scroll-action = "cycle-windows";
              animation-time = 0.05;
              custom-background-color = true;
              background-color = "rgb(36,31,49)";
              background-opacity = 0.9;
              transparency-mode = "FIXED";
              running-indicator-style = "DOTS";
              show-apps-always-in-the-edge = true;
            };
          }
          );
        }
      ];
    };

  };
}
