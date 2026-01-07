{ config, lib, ... }:

let
  programType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Application name";
      };
      exec = lib.mkOption {
        type = lib.types.str;
        description = "Command to execute";
      };
      delay = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Delay in seconds before starting (X-GNOME-Autostart-Delay)";
      };
    };
  };
in
{
  options = {
    smind.hm.autostart.programs = lib.mkOption {
      type = lib.types.listOf programType;
      default = [ ];
      description = "List of programs to autostart via XDG autostart";
    };
  };

  config = lib.mkIf (config.smind.hm.autostart.programs != [ ]) {
    home.file = builtins.listToAttrs
      (map
        (prog:
          {
            name = ".config/autostart/" + prog.name + ".desktop";
            value.text = ''
              [Desktop Entry]
              Type=Application
              Version=1.0
              Name=${prog.name}
              Exec=${prog.exec}
              StartupNotify=false
              Terminal=false
            '' + lib.optionalString (prog.delay != null) ''
              X-GNOME-Autostart-Delay=${toString prog.delay}
            '';
          })

        config.smind.hm.autostart.programs
      );
  };
}
