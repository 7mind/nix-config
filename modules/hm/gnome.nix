{ config, lib, ... }:

let
  runOrRaiseEnabled = config.smind.hm.globals.desktop.gnome.extensions.run-or-raise.enable;
in
{
  config = lib.mkIf runOrRaiseEnabled {
    xdg.configFile."run-or-raise/shortcuts.conf" = {
      text = "";
      force = true;
    };
  };
}
