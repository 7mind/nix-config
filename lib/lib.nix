args@{ lib, pkgs, cfg-meta, cfg-const, ... }:

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



  # be careful:
  # mkIf false { ... } → { _type = "if"; condition = false; content = { ... }; }
  # all the 

  deep_merge = list:
    let
      mergeTwo = a: b:
        if pkgs.lib.isAttrs a && pkgs.lib.isAttrs b then
          builtins.foldl'
            (acc: key:
              let
                aVal = if builtins.hasAttr key acc then acc.${key} else null;
                bVal = b.${key};
                newVal = if aVal == null then bVal else mergeTwo aVal bVal;
              in
              acc // { "${key}" = newVal; }
            )
            a
            (builtins.attrNames b)
        else if pkgs.lib.isList a && pkgs.lib.isList b then
          a ++ b
        else
        # In all other cases, the right-hand value wins.
          b;
    in
    builtins.foldl' mergeTwo { } list;

  merge_nixpkgs_modules = funcs:
    let
      mergeWithRecursiveUpdate = modules: pkgs.lib.foldl' pkgs.lib.recursiveUpdate { } modules;
      call_and_merge = funcs: args: deep_merge (map (f: f args) funcs);
      argsLists = map lib.functionArgs funcs;
      mergedArgs = mergeWithRecursiveUpdate argsLists;
      mergedFunc = lib.setFunctionArgs (call_and_merge funcs) mergedArgs;

    in
    mergedFunc;

  mk_container = outercfg: lib.recursiveUpdate (builtins.removeAttrs outercfg [ "privateUsersMultiplier" ])
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

      config = merge_nixpkgs_modules [
        ({ ... }: {
          imports = [
            "${cfg-meta.paths.modules}/container/container.nix"
            "${cfg-meta.paths.modules}/nixos/overlay.nix"
          ];
        })
        outercfg.config
      ];
    };
in
{
  _module.args.extend_pkg = extend_pkg;

  _module.args.outerConfig = outerConfig;

  _module.args.extended_pkg = extended_pkg;

  _module.args.xdg_associations = xdg_associations;

  _module.args.override_pkg = override_pkg;

  _module.args.mk_container = mk_container;

  _module.args.xdg_associate = input: {
    mimeApps = {
      enable = lib.mkDefault true;
      defaultApplications = xdg_associations input;
    };
  };
}
