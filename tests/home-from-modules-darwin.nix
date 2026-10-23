{ flake }:
let
  home = flake.globals.make-home-from-modules { inputs = flake.inputs; self = flake; } {
    modules = [
      ({ smind-hm, ... }: {
        imports = smind-hm.imports;
        smind.hm = {
          roles.server = true;
          dev.generic.enable = true;
          dev.git.enable = true;
          cleanups.enable = false;
        };
      })
    ];
    username = "engineer";
    host = {
      hostname = "darwin-fixture";
      system = "aarch64-darwin";
      homeDirectories.engineer = "/Users/engineer";
      globals = { };
    };
  };
in
# BG @regression: Darwin developer profiles must not lack the tmux fastfetch package.
assert home.value.pkgs.stdenv.hostPlatform.isDarwin;
home.value.activationPackage.drvPath
