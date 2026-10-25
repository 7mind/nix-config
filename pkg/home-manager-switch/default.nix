{ writeShellApplication, lib, coreutils, nix, util-linux, stdenv }:

writeShellApplication {
  name = "home-manager-profile";
  runtimeInputs = [ coreutils nix ] ++ lib.optionals stdenv.hostPlatform.isLinux [ util-linux ];
  text = builtins.readFile ./profile.sh;
}
