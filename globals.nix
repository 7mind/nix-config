rec {
  state-version-nixpkgs = "25.05";
  state-version-hm = "25.05";

  smind-nix-imports = builtins.concatLists [
    (import ./modules/nix/_imports.nix)
    (import ./lib/_imports.nix)
  ];

  smind-hm = {
    inherit state-version-hm;

    imports = builtins.concatLists [
      (import ./modules/hm/_imports.nix)
      (import ./lib/_imports.nix)
    ];
  };

  smconfig = { };

  make-nixos = { self, inputs, arch }: hostname:
    let
      pkgs = inputs.nixpkgs.legacyPackages."${arch}";
      paths = {
        root = "${self}";
        pkg = "${self}/pkg";
        lib = "${self}/lib";
        modules = "${self}/modules";
        modules-hm = "${self}/modules/hm";
        modules-nix = "${self}/modules/nix";
      };

      cfg-meta = {
        inherit arch;
        inherit state-version-nixpkgs;
        inherit paths;
        isLinux = true;
        isDarwin = false;
        jdk-main = pkgs.graalvm-ce;
      };

      cfg-flakes = {
        pkgs7mind = inputs.smind.legacyPackages."${arch}";
        nix-apple-fonts = inputs.nix-apple-fonts.packages."${arch}";
      };

      specialArgs = pkgs.lib.fix (self: {
        cfg-meta = cfg-meta;
        cfg-flakes = cfg-flakes;
        smind-hm = smind-hm;
        specialArgsSelfRef = self;
      });
    in
    {
      name = "${hostname}";
      value = inputs.nixpkgs.lib.nixosSystem
        {
          inherit specialArgs;
          system = "${arch}";
          modules = smind-nix-imports ++ [
            inputs.nix-apple-fonts.nixosModules
            inputs.home-manager.nixosModules.home-manager
            ./hosts/${hostname}/configuration.nix
          ];
        };
    };

  make-nixos-x86_64 = { inputs, self }: (make-nixos {
    inherit inputs;
    inherit self;
    arch = "x86_64-linux";
  });

}
