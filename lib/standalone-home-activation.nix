{ pkgs, home }:
let
  profile = pkgs.callPackage ../pkg/home-manager-switch { };
  switch = pkgs.writeShellScript "switch-home" (builtins.replaceStrings
    [ "@profileCommand@" ] [ (pkgs.lib.getExe profile) ]
    (builtins.readFile ../pkg/home-manager-switch/switch-home.sh));
  nixos = home.extendModules {
    modules = [ {
      submoduleSupport = { enable = true; externalPackageInstall = true; };
    } ];
  };
in
home.activationPackage.overrideAttrs (old: {
  buildCommand = old.buildCommand + ''
    ln -s ${switch} "$out/switch-home"
  '' + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
    ln -s ${nixos.activationPackage} "$out/nixos-generation"
  '';
})
