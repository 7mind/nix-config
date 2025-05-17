{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    #nixos-cosmic.url = "github:lilyinstarlight/nixos-cosmic";
    #nixos-cosmic.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self
    , nixpkgs
      # , nixos-cosmic
    , ...
    }: {
      nixosConfigurations =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        in
        {
          freshnix = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            modules = [
              # {
              #   nix.settings = {
              #     substituters = [ "https://cosmic.cachix.org/" ];
              #     trusted-public-keys = [ "cosmic.cachix.org-1:Dya9IyXD4xdBehWjrkPv6rtxpmMdRel02smYzA85dPE=" ];
              #   };
              # }
              # {
              #   services.desktopManager.cosmic.enable = true;
              #   services.displayManager.cosmic-greeter.enable = true;
              # }
              # nixos-cosmic.nixosModules.default

              ./configuration.nix
            ];
          };
        };
    };
}
