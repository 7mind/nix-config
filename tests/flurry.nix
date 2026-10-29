{ pkgs, inputs, packages }:
let
  lib = pkgs.lib;
  # The pinned nixpkgs 26.11 no longer supports x86_64-darwin.
  systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
  evaluate = system:
    let
      isLinux = lib.hasSuffix "-linux" system;
      cfg-meta = { inherit isLinux; isDarwin = !isLinux; };
      overlayModule = import ../modules/nix-generic/overlay.nix;
      homePkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = (overlayModule { pkgs = homePkgs; inherit cfg-meta; }).nixpkgs.overlays;
      };
      homeModules = [
        ../modules/hm/globals.nix
        ../modules/hm/env-settings-generic.nix
        {
          options.smind.hm.roles.desktop = lib.mkEnableOption "desktop fixture";
          config.home = {
            username = "engineer";
            homeDirectory = if isLinux then "/home/engineer" else "/Users/engineer";
            stateVersion = "26.05";
          };
        }
      ];
      homeArgs = {
        inherit cfg-meta;
        cfg-const = (import ../config.nix).const;
        xdg_associate = null;
      };
      home = settings: (inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = homePkgs;
        extraSpecialArgs = homeArgs;
        modules = homeModules ++ [ settings ];
      }).config;
      systemConfig = settings:
        ((if isLinux then inputs.nixpkgs.lib.nixosSystem else inputs.darwin.lib.darwinSystem) {
          specialArgs = { inherit cfg-meta inputs; };
          modules = [
            ../modules/nix-generic/overlay.nix
            ../modules/nix-generic/env-settings.nix
            (if isLinux then inputs.home-manager.nixosModules.home-manager else inputs.home-manager.darwinModules.home-manager)
            {
              options.smind.isDesktop = lib.mkEnableOption "desktop fixture";
              config = {
                nixpkgs.hostPlatform = system;
                nixpkgs.config.allowUnfree = true;
                system.stateVersion = if isLinux then "25.05" else 6;
                home-manager = {
                  useGlobalPkgs = true;
                  extraSpecialArgs = homeArgs;
                  users.engineer.imports = homeModules;
                };
              };
            }
            settings
          ];
        }).config;
      expectedPackage = homePkgs.callPackage ../pkg/flurry/package.nix { };
      exportPkgs = import inputs.nixpkgs { inherit system; };
      expectedExport = exportPkgs.callPackage ../pkg/flurry/package.nix { };
      enabledHome = home { };
      disabledHome = home { smind.hm.environment.sane-defaults.generic.enable = false; };
      replacedHome = home { home.packages = lib.mkForce [ homePkgs.hello ]; };
      enabledSystem = systemConfig { };
      disabledSystem = systemConfig { smind.environment.sane-defaults.enable = false; };
      replacedSystem = systemConfig { environment.systemPackages = lib.mkForce [ homePkgs.hello ]; };
      named = name: builtins.any (package: lib.getName package == name);
      flurry = list: lib.findFirst (package: lib.getName package == "flurry")
        (throw "Flurry missing from ${system} default packages") list;
    in
    # BG @specified: real module defaults, integration, and supported overrides.
    assert lib.assertMsg (named "flurry" enabledSystem.environment.systemPackages) "${system}: default system packages must include Flurry";
    assert lib.assertMsg (named "flurry" enabledHome.home.packages) "${system}: standalone Home Manager must include Flurry";
    assert lib.assertMsg (named "flurry" enabledSystem.home-manager.users.engineer.home.packages) "${system}: integrated Home Manager must include Flurry";
    assert lib.assertMsg (named "nnn" enabledSystem.environment.systemPackages && named "curl" enabledHome.home.packages) "${system}: existing default packages must be preserved";
    assert lib.assertMsg (!(named "flurry" disabledSystem.environment.systemPackages) && !(named "flurry" disabledHome.home.packages)) "${system}: existing sane-default switches must remain effective";
    assert lib.assertMsg (!(named "flurry" replacedSystem.environment.systemPackages) && !(named "flurry" replacedHome.home.packages)) "${system}: package list overrides must remain effective";
    assert lib.assertMsg (packages.${system}.flurry.meta.mainProgram == "flurry" && packages.${system}.flurry.stdenv.hostPlatform.system == system) "${system}: package export must target the requested platform";
    assert lib.assertMsg (builtins.all (list: (flurry list).drvPath == expectedPackage.drvPath) [
      enabledSystem.environment.systemPackages
      enabledHome.home.packages
      enabledSystem.home-manager.users.engineer.home.packages
    ]) "${system}: defaults must install the local Flurry package, not merely a matching name";
    assert lib.assertMsg (packages.${system}.flurry.drvPath == expectedExport.drvPath) "${system}: package export must build the local Flurry source";
    {
      export = packages.${system}.flurry.drvPath;
      systemDefault = (flurry enabledSystem.environment.systemPackages).drvPath;
      homeDefault = (flurry enabledHome.home.packages).drvPath;
      integratedHomeDefault = (flurry enabledSystem.home-manager.users.engineer.home.packages).drvPath;
    };
  results = map evaluate systems;
in
assert builtins.deepSeq results true;
pkgs.runCommand "flurry-default-packages" { } "touch $out"
