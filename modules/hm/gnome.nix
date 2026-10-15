{ config, lib, pkgs, ... }:

let
  cfg = config.smind.hm.desktop.gnome;
  extCfg = cfg.extensions;
  runOrRaiseEnabled = config.smind.hm.globals.desktop.gnome.extensions.run-or-raise.enable
    || (cfg.enable && extCfg.run-or-raise.enable);
in
{
  options.smind.hm.desktop.gnome = {
    enable = lib.mkEnableOption "per-user GNOME Shell extension provisioning";
    minimize-modifier = lib.mkOption {
      type = lib.types.str;
      default = "ctrl-alt";
      description = "Modifier for the Classic App Switcher's minimize shortcuts.";
    };
    extensions = lib.mkOption {
      type = lib.types.submodule (import ../shared/gnome-extensions.nix {
        inherit pkgs;
        minimizeModifier = cfg.minimize-modifier;
        defaults = {
          gsconnect = false;
          touchpadGestures = config.smind.hm.globals.three-finger-drag.enable;
          runOrRaise = config.smind.hm.globals.desktop.gnome.extensions.run-or-raise.enable;
        };
      });
      default = { };
      description = "Shared GNOME Shell extension policy.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      home.packages = extCfg.packages;
      xdg.desktopEntries."org.gnome.Extensions" = {
        name = "Extensions";
        exec = "${pkgs.gnome-shell}/bin/gnome-extensions-app";
        icon = "${pkgs.gnome-shell}/share/icons/hicolor/scalable/apps/org.gnome.Extensions.svg";
        categories = [ "GNOME" "GTK" "Utility" ];
        terminal = false;
      };
      # Ubuntu's running shell doesn't see extensions installed only in the Nix
      # profile's XDG_DATA_DIRS. A standard per-user extension location does.
      xdg.dataFile = builtins.listToAttrs (map (extension: {
        name = "gnome-shell/extensions/${extension.extensionUuid}";
        value.source = "${extension}/share/gnome-shell/extensions/${extension.extensionUuid}";
      }) extCfg.packages) // {
        "applications/org.gnome.Extensions.desktop".source =
          "${config.home.path}/share/applications/org.gnome.Extensions.desktop";
      };
      dconf.enable = true;
      dconf.settings = extCfg.dconfSettings;
    })
    (lib.mkIf runOrRaiseEnabled {
      xdg.configFile."run-or-raise/shortcuts.conf" = {
        text = "";
        force = true;
      };
    })
  ];
}
