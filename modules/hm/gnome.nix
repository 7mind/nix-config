{ lib, outerConfig, ... }:

let
  runOrRaiseEnabled = outerConfig.smind.desktop.gnome.extensions.run-or-raise.enable or false;
in
{
  config = lib.mkIf runOrRaiseEnabled {
    xdg.configFile."run-or-raise/shortcuts.conf" = {
      text = "";
      force = true;
    };
  };
}
