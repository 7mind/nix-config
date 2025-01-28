{ lib, pkgs, ... }:

let
  extend_pkg = { pkg, path, defs, ... }:
    let
      attrs = builtins.attrNames defs;
      mapper = name:
        "--suffix \"${name}\" : \"${defs."${name}"}\"";
      mapped = (map mapper attrs);
      more = lib.concatStringsSep " \\\n" mapped;
    in
    pkgs.symlinkJoin
      {
        name = "clion";
        paths = [ pkg ];
        buildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          wrapProgram $out/${path} \
            ${more}
        '';
      };

  extended_pkg = input@{ pkg, path, ... }:
    extend_pkg {
      inherit pkg;
      inherit path;
      defs = {
        LD_LIBRARY_PATH = lib.makeLibraryPath (input.ld-libs or [ ]);
        PATH = lib.strings.makeBinPath (input.paths or [ ]);
        COREFONTS_PATH = "${pkgs.corefonts}/share/fonts/truetype";
        FONTCONFIG_PATH = "/etc/fonts";
      } // (input.defs or { });
    };

  xdg_associations =
    { schemes, desktopfile }: builtins.listToAttrs
      (map
        (item: {
          name = item;
          value = desktopfile;
        })
        schemes
      );
in

{
  _module.args.extend_pkg = extend_pkg;

  _module.args.extended_pkg = extended_pkg;

  _module.args.xdg_associations = xdg_associations;

  _module.args.xdg_associate = input: {
    mimeApps = {
      enable = lib.mkDefault true;
      defaultApplications = xdg_associations input;
    };
  };

  _module.args.import_if_exists = path: if builtins.pathExists path then import path else { };
}
