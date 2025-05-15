args@{ lib, pkgs, cfg-meta, cfg-const, deep_merge, ... }:

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
        name = "${pkg.name}-custom";
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

  override_pkg = { pkg, path, ld-libs, ... }: pkg.overrideAttrs
    (oldAttrs: {
      buildInputs = (oldAttrs.buildInputs or [ ]) ++ ld-libs;
      nativeBuildInputs = (oldAttrs.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
      postFixup = ''
        wrapProgram $out/${path} --set LD_LIBRARY_PATH ${lib.makeLibraryPath ld-libs}
      '';
    });

  outerConfig =
    if (cfg-meta.isLinux) then args.nixosConfig else args.darwinConfig;


  call_and_merge = funcs: args: deep_merge (map (f: f args) funcs);

  merge_nixpkgs_modules = funcs:
    let
      argsLists = map lib.functionArgs funcs;
      mergedArgs = deep_merge argsLists;
      mergedFunc = lib.setFunctionArgs (call_and_merge funcs) mergedArgs;

    in
    mergedFunc;

  mk_container = outercfg: deep_merge [
    {
      autoStart = true;
      privateNetwork = true;
      specialArgs = {
        inherit cfg-meta;
        inherit cfg-const;
      };

      privateUsers = 65536 * outercfg.privateUsersMultiplier;

      extraFlags = [
        # "--private-users=${toString (65536 * offset)}:65536"
        "--private-users-ownership=chown"
      ];
    }

    (builtins.removeAttrs outercfg [ "privateUsersMultiplier" ])

    # {
    #   config = merge_nixpkgs_modules [
    #     ({ ... }: {
    #       imports = [
    #         "${cfg-meta.paths.modules}/container/container.nix"
    #         "${cfg-meta.paths.modules}/nixos/overlay.nix"
    #       ];
    #     })
    #     outercfg.config
    #   ];
    # }
  ];
in
{
  _module.args.extend_pkg = extend_pkg;

  _module.args.outerConfig = outerConfig;

  _module.args.extended_pkg = extended_pkg;

  _module.args.xdg_associations = xdg_associations;

  _module.args.override_pkg = override_pkg;

  _module.args.mk_container = mk_container;

  _module.args.merge_nixpkgs_modules = merge_nixpkgs_modules;

  _module.args.xdg_associate = input: {
    mimeApps = {
      enable = lib.mkDefault true;
      defaultApplications = xdg_associations input;
    };
  };
}
