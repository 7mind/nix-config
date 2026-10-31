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

  hibernateExtensionPatched = patchGnomeExtension (pkgs.callPackage ../../pkg/hibernate-status-button { });

  ghosttyCfg = config.smind.desktop.gnome.ghostty-toggle;

  extensions = extCfg.packages;
in
{
  options = {
    smind.desktop.gnome.allow-local-extensions = lib.mkEnableOption "local installation of GNOME Shell extensions (non-declaratively). When false, extension settings are locked via dconf";

    smind.desktop.gnome.extensions = lib.mkOption {
      type = lib.types.submodule (import ../shared/gnome-extensions.nix {
        inherit pkgs;
        minimizeModifier = config.smind.desktop.gnome.minimize-modifier;
        defaults = {
          gsconnect = config.smind.kdeconnect.selectedBackend == "gsconnect";
          touchpadGestures = config.smind.three-finger-drag.enable;
          runOrRaise = ghosttyCfg.enable;
        };
      });
      default = { };
      description = "Shared GNOME Shell extension policy.";
    };
  };

  config = lib.mkIf config.smind.desktop.gnome.enable {

    environment.systemPackages = extensions;
    smind.desktop.gnome.extensions.extraPackages =
      lib.optional hibernateCfg.enable hibernateExtensionPatched
      ++ lib.optional config.smind.desktop.gnome.sticky-keys.enable pkgs.gnomeExtensions.keyboard-modifiers-status
      ++ lib.optional hasKanataSwitcher config.services.kanata-switcher.gnomeExtension.package;

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

          settings = extCfg.dconfSettings;
        }
      ];
    };

  };
}
