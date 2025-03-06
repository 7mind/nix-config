rec {
  const = import ./config.nix;

  smind-nixos-imports = builtins.concatLists [
    (import ./lib/_imports.nix)
    (import ./modules/nix-generic/_imports.nix)
    (import ./modules/nixos/_imports.nix)
    (import ./roles/nixos/_imports.nix)
  ];

  smind-darwin-imports = builtins.concatLists [
    (import ./lib/_imports.nix)
    (import ./modules/nix-generic/_imports.nix)
    (import ./modules/darwin/_imports.nix)
    (import ./roles/darwin/_imports.nix)
  ];

  cfg-const = const.const;

  smind-hm = {
    imports = builtins.concatLists [
      (import ./lib/_imports.nix)
      (import ./modules/hm/_imports.nix)
      (import ./roles/hm/_imports.nix)
    ];
  };

  make = { self, inputs, arch }: hostname:
    let
      pkgs = inputs.nixpkgs.legacyPackages."${arch}";

      paths = {
        root = "${self}";
        pkg = "${self}/pkg";
        private = "${self}/private";
        secrets = "${self}/private/secrets";
        lib = "${self}/lib";
        modules = "${self}/modules";
        modules-hm = "${self}/modules/hm";
        modules-nix = "${self}/modules/nix";
        users = "${self}/users";
      };


      cfg-packages = const.cfg-packages {
        inherit inputs;
        inherit pkgs;
        inherit arch;
      };

      cfg-meta = rec {
        inherit arch;
        inherit paths;
        inherit inputs;
        inherit hostname;
        isLinux = pkgs.lib.hasSuffix "-linux" arch;
        isDarwin = pkgs.lib.hasSuffix "-darwin" arch;
        state-version-system = if isLinux then cfg-const.state-version-nixpkgs else cfg-const.state-version-darwin;
      };


      cfg-platform =
        if cfg-meta.isLinux then {
          generator = inputs.nixpkgs.lib.nixosSystem;

          flake-modules = smind-nixos-imports ++ [
            inputs.lanzaboote.nixosModules.lanzaboote
            inputs.nix-apple-fonts.nixosModules
            inputs.home-manager.nixosModules.home-manager
            inputs.agenix.nixosModules.default
            inputs.agenix-rekey.nixosModules.default
          ];

          hm-modules = [

          ];
        } else {
          generator = inputs.darwin.lib.darwinSystem;

          flake-modules = smind-darwin-imports ++ [
            inputs.home-manager.darwinModules.home-manager
            inputs.agenix.darwinModules.default
            # inputs.agenix-rekey.nixosModules.default
          ];

          hm-modules = [

          ];
        };

      cfg-flakes = {
        pkgs7mind = inputs.smind.legacyPackages."${arch}";
        nix-apple-fonts = inputs.nix-apple-fonts.packages."${arch}";
      };

      cfg-hm-modules = cfg-platform.hm-modules ++ [
        { home.stateVersion = cfg-const.state-version-hm; }
        inputs.agenix.homeManagerModules.default
      ];

      cfg-args = {
        smind-hm = [];
        inherit cfg-meta;
        inherit cfg-flakes;
        inherit cfg-packages;
        inherit cfg-hm-modules;
        inherit inputs;
        inherit cfg-const;
        import_if_exists = path: if builtins.pathExists path then import path else { }; # for some reason I can't add this into lib
      };
      specialArgs = cfg-args // {
        specialArgsSelfRef = cfg-args;
      };
    in
    {
      name = "${hostname}";
      value = cfg-platform.generator
        {
          inherit specialArgs;
          system = "${arch}";
          modules = cfg-platform.flake-modules ++ [
            { system.stateVersion = cfg-meta.state-version-system; }
            ./hosts/${hostname}/cfg-${hostname}.nix
          ];
        };
    };

  make-nixos-x86_64 = { inputs, self }: (make {
    inherit inputs;
    inherit self;
    arch = "x86_64-linux";
  });

  make-darwin-aarch64 = { inputs, self }: (make {
    inherit inputs;
    inherit self;
    arch = "aarch64-darwin";
  });
}
