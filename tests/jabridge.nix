{
  pkgs,
  inputs,
  packages,
}:
let
  lib = pkgs.lib;
  evaluate =
    system:
    let
      isLinux = lib.hasSuffix "-linux" system;
      cfg-meta = {
        inherit isLinux inputs;
        isDarwin = !isLinux;
      };
      overlayModule = import ../modules/nix-generic/overlay.nix;
      fixturePkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays =
          (overlayModule {
            pkgs = fixturePkgs;
            inherit cfg-meta;
          }).nixpkgs.overlays;
      };
      homeModules = [
        ../modules/hm/globals.nix
        ../modules/hm/env-settings-desktop.nix
        {
          home = {
            username = "engineer";
            homeDirectory = if isLinux then "/home/engineer" else "/Users/engineer";
            stateVersion = "26.05";
          };
        }
      ];
      homeArgs = {
        inherit cfg-meta;
        cfg-const = (import ../config.nix).const;
        xdg_associate = _: { };
      };
      home =
        settings:
        (inputs.home-manager.lib.homeManagerConfiguration {
          pkgs = fixturePkgs;
          extraSpecialArgs = homeArgs;
          modules = homeModules ++ [ settings ];
        }).config;
      enabledHome = home { smind.hm.globals.isDesktop = true; };
      serverHome = home { };
      disabledHome = home {
        smind.hm.globals.isDesktop = true;
        smind.hm.environment.sane-defaults.desktop.enable = false;
      };
      systemConfig =
        settings:
        (inputs.nixpkgs.lib.nixosSystem {
          specialArgs = { inherit cfg-meta; };
          modules = [
            ../modules/nix-generic/overlay.nix
            ../modules/nixos/env-settings-linux-desktop.nix
            inputs.home-manager.nixosModules.home-manager
            ({ lib, ... }: {
              options.smind = {
                isDesktop = lib.mkEnableOption "desktop fixture";
                hw.nvidia.enable = lib.mkEnableOption "NVIDIA fixture";
              };
              config = {
                nixpkgs.hostPlatform = system;
                nixpkgs.config.allowUnfree = true;
                nixpkgs.overlays = [
                  (final: _: {
                    extract-initrd = final.callPackage ../pkg/extract-initrd { };
                  })
                ];
                system.stateVersion = "26.05";
                users.users.engineer = {
                  isNormalUser = true;
                  home = "/home/engineer";
                };
                home-manager = {
                  useGlobalPkgs = true;
                  extraSpecialArgs = homeArgs;
                  users.engineer.imports = homeModules ++ [ { smind.hm.globals.isDesktop = true; } ];
                };
              };
            })
            settings
          ];
        }).config;
      enabledSystem = systemConfig { smind.isDesktop = true; };
      serverSystem = systemConfig { };
      disabledSystem = systemConfig {
        smind.isDesktop = true;
        smind.environment.linux.sane-defaults.desktop.enable = false;
      };
      hasPackage = list: lib.any (p: lib.getName p == "jabridge") list;
      expectedExport =
        (import inputs.nixpkgs { inherit system; }).callPackage ../pkg/jabridge/package.nix
          { };
      unitPath = "systemd/user/jabridge.service";
      wantsPath = "systemd/user/default.target.wants/jabridge.service";
      checkHome =
        config:
        assert lib.assertMsg (
          hasPackage config.home.packages == isLinux
        ) "${system}: desktop package selection";
        assert lib.assertMsg (
          builtins.hasAttr unitPath config.xdg.configFile == isLinux
        ) "${system}: desktop user unit selection";
        if isLinux then
          assert
            config.xdg.configFile.${unitPath}.source
            == "${fixturePkgs.jabridge}/lib/systemd/user/jabridge.service";
          assert config.xdg.configFile.${wantsPath}.source == config.xdg.configFile.${unitPath}.source;
          true
        else
          true;
      checkHomeDisabled =
        config:
        assert !(hasPackage config.home.packages);
        assert !(builtins.hasAttr unitPath config.xdg.configFile);
        assert !(builtins.hasAttr wantsPath config.xdg.configFile);
        true;
      checkSystemDisabled =
        config:
        assert !(hasPackage config.environment.systemPackages);
        assert !(hasPackage config.services.udev.packages);
        assert !(hasPackage config.systemd.packages);
        assert !(builtins.hasAttr "jabridge" config.systemd.user.services);
        true;
    in
    # BG @specified: real module defaults, desktop boundaries and opt-outs.
    assert checkHome enabledHome;
    assert checkHomeDisabled serverHome;
    assert checkHomeDisabled disabledHome;
    if isLinux then
      assert checkHome enabledSystem.home-manager.users.engineer;
      assert checkSystemDisabled serverSystem;
      assert checkSystemDisabled disabledSystem;
      assert hasPackage enabledSystem.environment.systemPackages;
      assert builtins.elem fixturePkgs.jabridge.drvPath (
        map (p: p.drvPath) enabledSystem.services.udev.packages
      );
      assert builtins.elem fixturePkgs.jabridge.drvPath (
        map (p: p.drvPath) enabledSystem.systemd.packages
      );
      assert enabledSystem.systemd.user.services.jabridge.wantedBy == [ "default.target" ];
      assert packages.${system}.jabridge.drvPath == expectedExport.drvPath;
      assert packages.${system}.jabridge.stdenv.hostPlatform.system == system;
      true
    else
      assert !(packages.${system} ? jabridge);
      true;
  results = map evaluate [
    "x86_64-linux"
    "aarch64-linux"
    "aarch64-darwin"
  ];
in
assert builtins.deepSeq results true;
pkgs.runCommand "jabridge-desktops" { } "touch $out"
