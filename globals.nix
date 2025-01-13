rec {
  state-version-nixpkgs = "25.05";
  state-version-hm = "25.05";

  smind-nix-imports = import ./modules/nix/_imports.nix ++ import ./lib/_imports.nix;

  smind-hm = {
    imports = import ./modules/hm/_imports.nix ++ import ./lib/_imports.nix;
    state-version = state-version-hm;
  };

  smconfig = {

  };
}
