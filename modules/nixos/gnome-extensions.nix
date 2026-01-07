{ config, lib, pkgs, cfg-meta, ... }:

let
  hibernateCfg = config.smind.desktop.gnome.hibernate;
  alsCfg = config.smind.desktop.gnome.ambient-light-sensor;
  fanControlCfg = config.smind.desktop.gnome.framework-fan-control;

  # Patch extensions to support current GNOME shell version
  patchGnomeExtension = ext: ext.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.jq ];
    postPatch = (old.postPatch or "") + ''
      jq '.["shell-version"] += ["${lib.versions.major pkgs.gnome-shell.version}"]' metadata.json > tmp.json && mv tmp.json metadata.json
    '';
  });

  hibernateExtensionPatched = patchGnomeExtension pkgs.gnomeExtensions.hibernate-status-button;

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
    # tray-icons-reloaded
  ]
  ++ lib.optional hibernateCfg.enable hibernateExtensionPatched
  ++ lib.optional config.smind.desktop.gnome.sticky-keys.enable gnomeExtensions.keyboard-modifiers-status
  ++ lib.optional fanControlCfg.enable gnomeExtensions.framework-fan-control;
in
{
  options = {
    smind.desktop.gnome.ambient-light-sensor.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable ambient light sensor support for GNOME's automatic screen brightness";
    };

    smind.desktop.gnome.framework-fan-control.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Framework fan control GNOME extension for Framework laptops";
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

    # Allow any local session to claim sensors from iio-sensor-proxy
    # The default policy requires "allow_active=yes" but D-Bus bus name subjects
    # may not properly resolve session state, so we allow unconditionally
    security.polkit.extraConfig = lib.mkIf alsCfg.enable ''
      polkit.addRule(function(action, subject) {
        if (action.id == "net.hadess.SensorProxy.claim-sensor") {
          return polkit.Result.YES;
        }
      });
    '';

    environment.systemPackages = extensions;

    # Enable fw-fanctrl service for Framework fan control extension
    hardware.fw-fanctrl.enable = lib.mkIf fanControlCfg.enable true;

    programs.dconf = {
      enable = true;
      profiles.user.databases = [
        {
          lockAll = true; # prevents overriding

          settings = {
            "org/gnome/shell" = {
              disable-user-extensions = false;
              enabled-extensions = map (e: e.extensionUuid) extensions;
            };

          };
        }
      ];
    };

  };
}
