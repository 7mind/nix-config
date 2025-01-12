{ lib, pkgs, ... }:

{
  _module.args.extend_pkg = { pkg, path, defs, ... }:
    let
      attrs = builtins.attrNames defs;
      mapper = name:
        "--suffix \"${name}\" : \"${defs."${name}"}\"";
      mapped = (map mapper (builtins.trace attrs attrs));
      more = lib.concatStringsSep " \\\n" mapped;
    in
    pkgs.symlinkJoin {
      name = "clion";
      paths = [ pkg ];
      buildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        wrapProgram $out/${path} \
          ${builtins.trace more more}
      '';
    };

  _module.args.extended_pkg = input@{ pkg, path, extend_pkg, ... }:
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
}
