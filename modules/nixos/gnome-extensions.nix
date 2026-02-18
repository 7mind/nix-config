{ config, lib, pkgs, cfg-meta, ... }:

let
  hibernateCfg = config.smind.power-management.hibernate;
  alsCfg = config.smind.desktop.gnome.ambient-light-sensor;
  fanControlCfg = config.smind.desktop.gnome.framework-fan-control;
  batteryHealthCfg = config.smind.desktop.gnome.battery-health-charging;
  kanataSwitcherCfg = config.smind.keyboard.super-remap.kanata-switcher;
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

  # Patch battery-health-charging to use NixOS paths instead of /usr/local/bin
  batteryHealthChargingPatched = pkgs.gnomeExtensions.battery-health-charging.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      # Replace hardcoded /usr/local/bin path with NixOS system path
      substituteInPlace lib/driver.js \
        --replace-fail '/usr/local/bin/batteryhealthchargingctl-''${user}' \
                       '/run/current-system/sw/bin/batteryhealthchargingctl'
    '';
  });

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
  ++ lib.optional hibernateCfg.enable hibernateExtensionPatched
  ++ lib.optional config.smind.desktop.gnome.sticky-keys.enable gnomeExtensions.keyboard-modifiers-status
  ++ lib.optional fanControlCfg.enable gnomeExtensions.framework-fan-control
  ++ lib.optional batteryHealthCfg.enable batteryHealthChargingPatched
  ++ lib.optional kanataSwitcherCfg.enable config.services.kanata-switcher.gnomeExtension.package;
in
{
  options = {
    smind.desktop.gnome.ambient-light-sensor.enable = lib.mkEnableOption "ambient light sensor support for GNOME's automatic screen brightness";

    smind.desktop.gnome.framework-fan-control.enable = lib.mkEnableOption "Framework fan control GNOME extension for Framework laptops";

    smind.desktop.gnome.battery-health-charging.enable = lib.mkEnableOption "Battery Health Charging GNOME extension for laptops";

    smind.desktop.gnome.allow-local-extensions = lib.mkEnableOption "local installation of GNOME Shell extensions (non-declaratively). When false, extension settings are locked via dconf";

    smind.desktop.gnome.extensions = {
      appindicator.enable = lib.mkEnableOption "AppIndicator/KStatusNotifierItem support for the GNOME Shell" // { default = true; };
      gsconnect.enable = lib.mkEnableOption "GSConnect - KDE Connect implementation for GNOME" // {
        default = config.smind.kdeconnect.backend == "gsconnect";
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
      dash-to-dock.enable = lib.mkEnableOption "dash-to-dock extension" // { default = false; };
      dash2dock-lite.enable = lib.mkEnableOption "dash2dock-lite extension" // { default = false; };
      no-overview.enable = lib.mkEnableOption "no-overview extension - skip overview on login" // { default = false; };
      run-or-raise.enable = lib.mkEnableOption "run-or-raise extension (D-Bus always enabled)" // { default = ghosttyCfg.enable; };
    };
  };

  config = lib.mkIf config.smind.desktop.gnome.enable {

    # Enable iio-sensor-proxy for ambient light sensor support (GNOME 49+ uses this natively)
    hardware.sensor.iio.enable = lib.mkIf alsCfg.enable true;

    # Enable IIO buffer scan elements for HID ambient light sensor (Framework 16)
    # This ensures iio-sensor-proxy can read the sensor via buffer mode
    services.udev.extraRules = lib.mkIf alsCfg.enable ''
      # Enable illuminance scan element for ALS buffer mode
      ACTION=="add", SUBSYSTEM=="iio", ATTR{name}=="als", ATTR{scan_elements/in_illuminance_en}="1"
    '';

    environment.systemPackages = extensions
      # Battery Health Charging extension control script (patched for NixOS)
      # The original script's CHECKINSTALLATION tries to compare polkit rules files
      # which don't exist on NixOS (we use security.polkit.extraConfig instead)
      ++ lib.optional batteryHealthCfg.enable (pkgs.runCommand "batteryhealthchargingctl" { } ''
      mkdir -p $out/bin
      cp ${batteryHealthChargingPatched}/share/gnome-shell/extensions/Battery-Health-Charging@maniacx.github.com/resources/batteryhealthchargingctl $out/bin/batteryhealthchargingctl
      chmod +x $out/bin/batteryhealthchargingctl
      # Patch CHECKINSTALLATION case to always succeed on NixOS
      # We configure polkit declaratively, so no need to check file-based rules
      # Only replace the call site, not the function definition
      sed -i '/^    CHECKINSTALLATION)$/,/^        ;;$/{
        s/check_installation/echo "NixOS: polkit configured declaratively"; exit 0/
      }' $out/bin/batteryhealthchargingctl
    '');

    # Polkit rules for GNOME extensions
    security.polkit.extraConfig = lib.mkMerge [
      ''
        // Allow any local session to claim sensors from iio-sensor-proxy (ALS)
        polkit.addRule(function(action, subject) {
          if (action.id == "net.hadess.SensorProxy.claim-sensor") {
            return polkit.Result.YES;
          }
        });
      ''
      (lib.mkIf batteryHealthCfg.enable ''
        // Allow Battery Health Charging extension to set thresholds
        // Note: Don't check subject.active - after suspend/resume it may not be set immediately
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.policykit.exec" &&
              action.lookup("program") == "/run/current-system/sw/bin/batteryhealthchargingctl" &&
              subject.local && subject.isInGroup("wheel"))
          {
            return polkit.Result.YES;
          }
        });
      '')
    ];

    # Enable fw-fanctrl service for Framework fan control extension
    hardware.fw-fanctrl.enable = lib.mkIf fanControlCfg.enable true;
    hardware.fw-fanctrl.disableBatteryTempCheck = lib.mkIf fanControlCfg.enable true;

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
          } ++ lib.optional batteryHealthCfg.enable {
            # Tell Battery Health Charging extension that polkit is installed
            "org/gnome/shell/extensions/Battery-Health-Charging" = {
              polkit-status = "installed";
            };
          });
        }
      ];
    };

  };
}
