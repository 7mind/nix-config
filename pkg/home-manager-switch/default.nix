{ writeShellScriptBin, lib, coreutils, nix, util-linux, stdenv }:

writeShellScriptBin "home-manager-profile" ''
  export PATH=${lib.makeBinPath ([ coreutils nix ] ++ lib.optionals stdenv.hostPlatform.isLinux [ util-linux ])}:$PATH
  ${builtins.readFile ./profile.sh}
''
