{ config, lib, pkgs, cfg-meta, ... }:

let
  hibernateCfg = config.smind.power-management.hibernate;
  alsCfg = config.smind.desktop.gnome.ambient-light-sensor;
  fanControlCfg = config.smind.desktop.gnome.framework-fan-control;
  batteryHealthCfg = config.smind.desktop.gnome.battery-health-charging;
  kanataSwitcherCfg = config.smind.keyboard.super-remap.kanata-switcher;

  # Patch extensions to support current GNOME shell version
  patchGnomeExtension = ext: ext.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.jq ];
    postPatch = (old.postPatch or "") + ''
      jq '.["shell-version"] += ["${lib.versions.major pkgs.gnome-shell.version}"]' metadata.json > tmp.json && mv tmp.json metadata.json
    '';
  });

  hibernateExtensionPatched = patchGnomeExtension pkgs.gnomeExtensions.hibernate-status-button;

  # Patch battery-health-charging to use NixOS paths instead of /usr/local/bin
  batteryHealthChargingPatched = pkgs.gnomeExtensions.battery-health-charging.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      # Replace hardcoded /usr/local/bin path with NixOS system path
      substituteInPlace lib/driver.js \
        --replace-fail '/usr/local/bin/batteryhealthchargingctl-''${user}' \
                       '/run/current-system/sw/bin/batteryhealthchargingctl'
    '';
  });

  extensions = with pkgs; [
    # This is a dirty fix for annoying "allow inhibit shortcuts?" popups
    # https://discourse.gnome.org/t/virtual-machine-manager-wants-to-inhibit-shortcuts/26017/8
    # https://unix.stackexchange.com/questions/417670/virtual-machine-manager-wants-to-inhibit-shortcuts-again-and-again-on-waylan
    # https://askubuntu.com/questions/1488341/how-do-i-inhibit-shortcuts-for-virtual-machines
    # https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.impl.portal.PermissionStore.html
    gnome-shortcut-inhibitor
    gnomeExtensions.appindicator
    gnomeExtensions.gsconnect
    gnomeExtensions.native-window-placement
    gnomeExtensions.caffeine
    gnomeExtensions.vicinae
    gnomeExtensions.steal-my-focus-window
    gnomeExtensions.dim-completed-calendar-events
    gnomeExtensions.tiling-shell
    # gnomeExtensions.open-bar


    # gnomeExtensions.grand-theft-focus
    # gnomeExtensions.highlight-focus
    # tray-icons-reloaded
  ]
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
      profiles.user.databases = [
        {
          lockAll = !config.smind.desktop.gnome.allow-local-extensions;

          settings = lib.mkMerge ([
            {
              "org/gnome/shell" = {
                disable-user-extensions = false;
                enabled-extensions = map (e: e.extensionUuid) extensions;
              };
            }
          ] ++ lib.optional batteryHealthCfg.enable {
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
