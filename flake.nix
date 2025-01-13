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

        state-version-nixpkgs = "25.05";
        state-version-hm = "25.05";

        paths = {
          root = "${self}";
          pkg = "${self}/pkg";
        };

        smind-nix-imports = import ./modules/nix/_imports.nix ++ import ./lib/_imports.nix;

        smind-hm = {
          imports = import ./modules/hm/_imports.nix ++ import ./lib/_imports.nix;
          state-version = state-version-hm;
        };

        cfgmeta = {
          isLinux = true;
          isDarwin = false;
          paths = paths;
          jdk-main = pkgs.graalvm-ce;
          state-version-nixpkgs = state-version-nixpkgs;
        };

        cfgnix = {
          pkgs7mind = inputs.smind.legacyPackages."${arch}";
          nix-apple-fonts = inputs.nix-apple-fonts.packages."${arch}";
        };

        specialArgs = {
          cfgmeta = cfgmeta;
          cfgnix = cfgnix;
          smind-hm = smind-hm;
        };
      in
      {
        pavel-am5 = inputs.nixpkgs.lib.nixosSystem {
          system = "${arch}";
          modules = [
            {
              system.stateVersion = state-version-hm;
            }
            inputs.nix-apple-fonts.nixosModules
            inputs.home-manager.nixosModules.home-manager
            {
              home-manager.extraSpecialArgs = specialArgs;
            }
            ./configuration.nix
          ] ++
          smind-nix-imports
          ;

          specialArgs = specialArgs;
        };
      };
  };
}
