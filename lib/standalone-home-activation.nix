{ pkgs, home }:
let
  profile = pkgs.callPackage ../pkg/home-manager-switch { };
  switch = pkgs.writeShellApplication {
    name = "switch-home";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.replaceStrings [ "@profileCommand@" ] [ (pkgs.lib.getExe profile) ]
      (builtins.readFile ../pkg/home-manager-switch/switch-home.sh);
  };
  nixos = home.extendModules {
    modules = [ {
      submoduleSupport = { enable = true; externalPackageInstall = true; };
    } ];
  };
in
home.activationPackage.overrideAttrs (old: {
  buildCommand = old.buildCommand + ''
    ln -s ${pkgs.lib.getExe switch} "$out/switch-home"
  '' + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
    ln -s ${nixos.activationPackage} "$out/nixos-generation"
  '';
})
