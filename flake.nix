{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";


    smind = {
      url = "github:7mind/7mind-nix/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-apple-fonts = {
      url = "github:braindefender/nix-apple-fonts/6f1a4b74cb889c7bc28d378715c79b4d0b35f5b8";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, ... }: {
    nixosConfigurations =
      let
        arch = "x86_64-linux";
        pkgs = inputs.nixpkgs.legacyPackages."${arch}";
        paths = {
          root = "${self}";
          pkg = "${self}/pkgs";
        };
        cfgmeta = {
          isLinux = true;
          isDarwin = false;
          paths = paths;
          jdk-main = pkgs.graalvm-ce;
        };
        cfgnix = {
          pkgs7mind = inputs.smind.legacyPackages."${arch}";
          nix-apple-fonts = inputs.nix-apple-fonts.packages."${arch}";
        };
        # cfgtools = { config, ... }: rec {
        # };


        specialArgs = {
          cfgmeta = cfgmeta;
          cfgnix = cfgnix;
          # cfgtools = cfgtools;
        };
      in
      {
        freshnix = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./modules/nix/flake-lib.nix

            inputs.nix-apple-fonts.nixosModules
            inputs.home-manager.nixosModules.home-manager
            {
              home-manager.extraSpecialArgs = specialArgs;
            }
            ./configuration.nix
            # cfgtools
          ];

          specialArgs = specialArgs;
        };
      };
  };
}
