{ config, lib, ... }:

{
  options = {
    smind.hm.autostart.programs = lib.mkOption {
      # also useful: types.listOf types.anything
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "";
    };
  };

  config = lib.mkIf (config.smind.hm.autostart.programs != [ ]) {
    home.file = builtins.listToAttrs
      (map
        (pkg:
          {
            name = ".config/autostart/" + pkg.name + ".desktop";
            value.text = ''
              [Desktop Entry]
              Type=Application
              Version=1.0
              Name=${pkg.name}
              Exec=${pkg.exec}
              StartupNotify=false
              Terminal=false
            '';
          })

        config.smind.hm.autostart.programs
      );
  };
}
