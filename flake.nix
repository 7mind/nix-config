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

  outputs = inputs@{ self, ... }:
    let
      globals = import ./globals.nix;

      paths = {
        root = "${self}";
        pkg = "${self}/pkg";
        lib = "${self}/lib";
        modules = "${self}/modules";
        modules-hm = "${self}/modules/hm";
        modules-nix = "${self}/modules/nix";
      };


      make-nixos = cfg:
        let
          arch = cfg.arch;
          pkgs = inputs.nixpkgs.legacyPackages."${arch}";
          cfg-meta = {
            isLinux = true;
            isDarwin = false;
            paths = paths;
            jdk-main = pkgs.graalvm-ce;
            state-version-nixpkgs = globals.state-version-nixpkgs;
          };

          cfg-flakes = {
            pkgs7mind = inputs.smind.legacyPackages."${arch}";
            nix-apple-fonts = inputs.nix-apple-fonts.packages."${arch}";
          };

          specialArgs = pkgs.lib.fix (self: {
            cfg-meta = cfg-meta;
            cfg-flakes = cfg-flakes;
            smind-hm = globals.smind-hm;
            specialArgsSelfRef = self;
          });
        in
        {
          name = "${cfg.hostname}";
          value = inputs.nixpkgs.lib.nixosSystem
            {
              system = "${arch}";

              modules = globals.smind-nix-imports ++ [
                inputs.nix-apple-fonts.nixosModules
                inputs.home-manager.nixosModules.home-manager
                ./hosts/pavel-am5/configuration.nix
              ];

              specialArgs = specialArgs;
            };
        };
    in
    {
      nixosConfigurations = builtins.listToAttrs
        (map (item: item) [
          (make-nixos
            { arch = "x86_64-linux"; hostname = "pavel-am5"; })
        ]);

      # let
      #   arch = "x86_64-linux";
      #   pkgs = inputs.nixpkgs.legacyPackages."${arch}";

      #   cfg-meta = {
      #     isLinux = true;
      #     isDarwin = false;
      #     paths = paths;
      #     jdk-main = pkgs.graalvm-ce;
      #     state-version-nixpkgs = globals.state-version-nixpkgs;
      #   };

      #   cfg-flakes = {
      #     pkgs7mind = inputs.smind.legacyPackages."${arch}";
      #     nix-apple-fonts = inputs.nix-apple-fonts.packages."${arch}";
      #   };

      #   specialArgs = pkgs.lib.fix (self: {
      #     cfg-meta = cfg-meta;
      #     cfg-flakes = cfg-flakes;
      #     smind-hm = globals.smind-hm;
      #     specialArgsSelfRef = self;
      #   });
      # in
      # {
      #   pavel-am5 = inputs.nixpkgs.lib.nixosSystem {
      #     system = "${arch}";

      #     modules = globals.smind-nix-imports ++ [
      #       inputs.nix-apple-fonts.nixosModules
      #       inputs.home-manager.nixosModules.home-manager
      #       ./hosts/pavel-am5/configuration.nix
      #     ];

      #     specialArgs = specialArgs;
      #   };
      # };
    };
}
