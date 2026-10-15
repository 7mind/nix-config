{ pkgs, defaults, minimizeModifier }:
{ config, lib, ... }:

let
  cfg = config;
  packageForShell = package:
    if cfg.shellVersion == lib.versions.major pkgs.gnome-shell.version then package
    else
      let
        extensions = pkgs."gnome${cfg.shellVersion}Extensions" or
          (throw "No GNOME ${cfg.shellVersion} extension catalog in the pinned nixpkgs");
      in
      extensions.${package.extensionUuid} or
        (throw "GNOME extension ${package.extensionUuid} does not support Shell ${cfg.shellVersion}");
  catalog = [
    { name = "run-or-raise"; package = pkgs.gnomeExtensions.run-or-raise; }
    # AppIndicator v64 registers SNI items but does not render them on GNOME 50: https://github.com/ubuntu/gnome-shell-extension-appindicator/issues/628
    { name = "status-tray"; package = pkgs.gnomeExtensions.status-tray; }
    { name = "gsconnect"; package = pkgs.gnomeExtensions.gsconnect; }
    { name = "native-window-placement"; package = pkgs.gnomeExtensions.native-window-placement; }
    { name = "caffeine"; package = pkgs.gnomeExtensions.caffeine; }
    { name = "vicinae"; package = pkgs.gnomeExtensions.vicinae; }
    { name = "steal-my-focus-window"; package = pkgs.gnomeExtensions.steal-my-focus-window; }
    { name = "dim-completed-calendar-events"; package = pkgs.gnomeExtensions.dim-completed-calendar-events; }
    { name = "rounded-window-corners-reborn"; package = pkgs.gnomeExtensions.rounded-window-corners-reborn; }
    { name = "tiling-shell"; package = pkgs.gnomeExtensions.tiling-shell; }
    { name = "open-bar"; package = pkgs.gnomeExtensions.open-bar; }
    { name = "grand-theft-focus"; package = pkgs.gnomeExtensions.grand-theft-focus; }
    { name = "highlight-focus"; package = pkgs.gnomeExtensions.highlight-focus; }
    { name = "tray-icons-reloaded"; package = pkgs.gnomeExtensions.tray-icons-reloaded; }
    { name = "dash-to-dock"; package = pkgs.gnomeExtensions.dash-to-dock; }
    { name = "dash2dock-lite"; package = pkgs.gnomeExtensions.dash2dock-lite; }
    { name = "no-overview"; package = pkgs.gnomeExtensions.no-overview; }
  ];
  extensions = [
    # This is a dirty fix for annoying "allow inhibit shortcuts?" popups
    # https://discourse.gnome.org/t/virtual-machine-manager-wants-to-inhibit-shortcuts/26017/8
    # https://unix.stackexchange.com/questions/417670/virtual-machine-manager-wants-to-inhibit-shortcuts-again-and-again-on-waylan
    # https://askubuntu.com/questions/1488341/how-do-i-inhibit-shortcuts-for-virtual-machines
    # https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.impl.portal.PermissionStore.html
    pkgs.gnome-shortcut-inhibitor
  ]
  ++ lib.concatMap (extension:
    lib.optional cfg.${extension.name}.enable (packageForShell extension.package)
  ) catalog
  ++ lib.optional cfg.classic-app-switcher.enable pkgs.gnome-shell-extension-classic-app-switcher
  ++ lib.optional cfg.touchpad-gesture-customization.enable pkgs.gnome-shell-extension-touchpad-gesture-customization-app-expose
  ++ cfg.extraPackages;
in
{
  options = {
    shellVersion = lib.mkOption {
      type = lib.types.str;
      default = lib.versions.major pkgs.gnome-shell.version;
      description = "Major version of the GNOME Shell that will load these extensions.";
    };
    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Additional host-specific GNOME extensions to install and enable.";
    };
    extraEnabledExtensions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "UUIDs of extensions provided by the host distribution rather than Nix.";
    };
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      readOnly = true;
      description = "Selected GNOME extension packages.";
    };
    dconfSettings = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      description = "Shared GNOME extension activation and settings.";
    };
    status-tray.enable = lib.mkEnableOption "Status Tray support for AppIndicator/KStatusNotifierItem applications" // { default = true; };
    gsconnect.enable = lib.mkEnableOption "GSConnect - KDE Connect implementation for GNOME" // { default = defaults.gsconnect; };
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
        super-num-hotkeys = lib.mkEnableOption "enable dash-to-dock super-<N> hotkeys" // { default = false; };
      };
    };
    dash2dock-lite.enable = lib.mkEnableOption "dash2dock-lite extension" // { default = false; };
    no-overview.enable = lib.mkEnableOption "no-overview extension - skip overview on login" // { default = false; };
    classic-app-switcher = {
      enable = lib.mkEnableOption "Classic App Switcher extension (custom fork)" // { default = false; };
      mac-like-config.enable = lib.mkEnableOption "mac-like options for classic-app-switcher" // { default = true; };
      extra-hotkeys.enable = lib.mkEnableOption "hide-others / show-all-apps hotkeys for classic-app-switcher" // { default = true; };
    };
    touchpad-gesture-customization = {
      enable = lib.mkEnableOption "Touchpad Gesture Customization — remap touchpad gestures" // { default = defaults.touchpadGestures; };
      remap-3-to-4 = lib.mkEnableOption "remap GNOME's 3-finger gestures to 4-finger (frees 3-finger for drag)" // { default = defaults.touchpadGestures; };
    };
    run-or-raise.enable = lib.mkEnableOption "run-or-raise extension (D-Bus always enabled)" // { default = defaults.runOrRaise; };
  };

  config = {
    packages = extensions;
    dconfSettings = {
      "org/gnome/shell" = {
        disable-user-extensions = false;
        enabled-extensions = lib.unique ((map (extension: extension.extensionUuid) extensions) ++ cfg.extraEnabledExtensions);
      };
    } // lib.optionalAttrs cfg.run-or-raise.enable {
      "org/gnome/shell/extensions/run-or-raise".dbus = true;
    } // lib.optionalAttrs cfg.touchpad-gesture-customization.enable {
      "org/gnome/shell/extensions/touchpad-gesture-customization" = {
        # Turn on the app-expose gesture this fork adds: a downward
        # swipe opens the application overview (app spread). Exactly one
        # vertical swipe must drive overview navigation — use 4-finger
        # so 3-finger stays free for linux-3-finger-drag.
        overview-navigation-states = "APPLICATION_OVERVIEW_ON_DOWN";
        vertical-swipe-4-fingers-gesture = "OVERVIEW_NAVIGATION";
        group-overview-by-application = true;
      }
      # Move GNOME's default 3-finger swipe gestures to NONE, freeing
      # 3-finger input for linux-3-finger-drag.
      // lib.optionalAttrs cfg.touchpad-gesture-customization.remap-3-to-4 {
        vertical-swipe-3-fingers-gesture = "NONE";
        horizontal-swipe-3-fingers-gesture = "NONE";
        pinch-3-finger-gesture = "NONE";
      };
    } // lib.optionalAttrs (cfg.dash-to-dock.enable && cfg.dash-to-dock.unity-like-config.enable) {
      "org/gnome/shell/extensions/dash-to-dock" = {
        dock-position = "LEFT";
        dock-fixed = false; # due to upstream bug, only panel mode works for autohide
        custom-theme-shrink = true;
        hot-keys = cfg.dash-to-dock.unity-like-config.super-num-hotkeys;
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
    } // lib.optionalAttrs (cfg.classic-app-switcher.enable && cfg.classic-app-switcher.mac-like-config.enable) {
      "org/gnome/shell/extensions/classic-app-switcher" = import ../../lib/gnome-classic-app-switcher.nix {
        inherit lib minimizeModifier;
        extraHotkeys = cfg.classic-app-switcher.extra-hotkeys.enable;
      };
    };
  };
}
