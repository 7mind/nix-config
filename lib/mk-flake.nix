{ inputs, self, privateRoot ? null }:
let
  globals = import ../globals.nix { inherit privateRoot; };
  hosts-public = import ../hosts.nix;
  hosts-private = globals.importPrivate "hosts.nix" (
    { ... }: {
      nixos = [ ];
      darwin = [ ];
    }
  );
  builders = {
    make-nixos-x86_64 = globals.make-nixos-x86_64 {
      inherit inputs;
      inherit self;
    };
    make-nixos-aarch64 = globals.make-nixos-aarch64 {
      inherit inputs;
      inherit self;
    };
    make-darwin-aarch64 = globals.make-darwin-aarch64 {
      inherit inputs;
      inherit self;
    };
    make-home = globals.make-home {
      inherit inputs self;
    };
  };
  homes = (hosts-public builders).home ++ ((hosts-private builders).home or [ ]);
in
{
  inherit globals; # this makes this flake reusable by other flakes

  lib.mkFlake = import ./mk-flake.nix;

  nixosConfigurations = builtins.listToAttrs (
    (hosts-public builders).nixos ++ (hosts-private builders).nixos
  );

  darwinConfigurations = builtins.listToAttrs (
    (hosts-public builders).darwin ++ (hosts-private builders).darwin
  );

  homeConfigurations = builtins.listToAttrs homes;

  homeMeta = builtins.listToAttrs (map (home: {
    inherit (home) name;
    value = { inherit (home) hostname username platform; };
  }) homes);

  agenix-rekey = inputs.agenix-rekey.configure {
    userFlake = self;
    nixosConfigurations = self.nixosConfigurations // self.darwinConfigurations;
    homeConfigurations = inputs.nixpkgs.lib.filterAttrs
      (_: home: home.config.age.enable) self.homeConfigurations;
  };

  agenix-rekey-homes = builtins.mapAttrs
    (
      name: home:
        inputs.agenix-rekey.configure {
          userFlake = self;
          homeConfigurations = { ${name} = home; };
        }
    )
    self.homeConfigurations;

  agenix-rekey-hosts = builtins.mapAttrs
    (
      name: _:
        inputs.agenix-rekey.configure {
          userFlake = self;
          nixosConfigurations = {
            ${name} = (self.nixosConfigurations // self.darwinConfigurations).${name};
          };
        }
    )
    (self.nixosConfigurations // self.darwinConfigurations);

  hostMeta =
    let
      allConfigs = self.nixosConfigurations // self.darwinConfigurations;
      extractMeta =
        name: cfg:
        let
          config = cfg.config;
          smindHost = config.smind.host;
        in
        {
          platform = if builtins.hasAttr name self.darwinConfigurations then "darwin" else "linux";
          group = smindHost.group;
          fqn = smindHost.fqn;
          owner = smindHost.owner;
        };
    in
    builtins.mapAttrs extractMeta allConfigs;
}
// inputs.flake-utils.lib.eachDefaultSystem (
  system:
  let
    privateOutputs =
      (globals.importPrivate "flake-outputs.nix" (_: {
        overlays = [ ];
        packages = { };
        checks = { };
      }))
        { inherit pkgs; publicRoot = (globals.pathsFor self).root; };
    pkgs = import inputs.nixpkgs {
      localSystem = system;
      overlays = [
        inputs.agenix-rekey.overlays.default
        (import ../pkg/openlinkhub/overlay.nix)
        (final: _: { flurry = final.callPackage ../pkg/flurry/package.nix { }; })
      ]
      ++ privateOutputs.overlays;
    };
  in
  {
    inherit pkgs;
    packages = {
      flurry = pkgs.flurry;
      home-manager-cli = inputs.home-manager.packages.${system}.default;
    }
    // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
      hyprwhspr = pkgs.callPackage ../pkg/hyprwhspr { src = inputs.hyprwhspr; };
    }
    // privateOutputs.packages;
    checks = {
      flurry = pkgs.flurry;
      flurry-default-packages = import ../tests/flurry.nix {
        inherit pkgs inputs;
        packages = self.packages;
      };
    } // inputs.nixpkgs.lib.optionalAttrs
        (builtins.elem system [
          "x86_64-linux"
          "aarch64-linux"
        ])
        (

      {
            home-configurations =
              let
                capabilities = import ../tests/home-host-capabilities.nix {
                  inherit pkgs;
                  lib = pkgs.lib;
                  profiles = globals.importPrivate "tests/home-host-capabilities.nix" [ ];
                };
                contexts = import ../tests/home-context.nix { flake = self; inherit privateRoot; };
                explicitModules = import ../tests/home-from-modules.nix { flake = self; };
                darwinModules = import ../tests/home-from-modules-darwin.nix { flake = self; };
                credentials = import ../tests/dev-llm-credentials.nix { flake = self; };
                firefox = import ../tests/firefox.nix { flake = self; };
              in
              assert builtins.deepSeq [ capabilities contexts explicitModules darwinModules credentials firefox ] true;
              pkgs.runCommand "home-configurations" { } "touch $out";
            home-shell = import ../tests/home-shell.nix { inherit pkgs; home-manager = inputs.home-manager; };
            nix-access-tokens = import ../tests/nix-access-tokens.nix { inherit pkgs; home-manager = inputs.home-manager; };
            gnome-extensions = import ../tests/gnome-extensions.nix { inherit pkgs inputs; home-manager = inputs.home-manager; };
            gnome-mouse = import ../tests/gnome-mouse.nix { inherit pkgs; };
            netbird = import ../tests/netbird.nix { inherit pkgs; };
            promoted-core = import ../tests/promoted-core.nix { inherit pkgs; };
            promoted-mosquitto = import ../tests/promoted-mosquitto.nix { inherit pkgs; };
            llama-swap = import ../tests/llama-swap.nix { inherit pkgs inputs; };
            asterisk-linphone-fallback = import ../tests/asterisk-linphone-fallback.nix { inherit pkgs; };
            flexisip-file-transfer = import ../tests/flexisip.nix { inherit pkgs; };
            openlinkhub = import ../tests/openlinkhub.nix { inherit pkgs; };
            home-manager-persistence = import ../tests/home-manager-persistence.nix { inherit pkgs; flake = self; };
            searxng = import ../tests/searxng.nix { inherit pkgs; };
          }
          // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
            hyprwhspr = import ../tests/hyprwhspr.nix {
              inherit pkgs;
              package = self.packages.${system}.hyprwhspr;
            };
          }
          // pkgs.lib.optionalAttrs (privateRoot != null) {
            switch-hm = pkgs.runCommand "switch-hm-test" {
              nativeBuildInputs = [ pkgs.bash pkgs.git pkgs.python3 pkgs.jq ]
                ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.util-linux ];
            } ''
              mkdir -p checkout/tests
              cp ${privateRoot}/switch-hm checkout/switch-hm
              chmod +x checkout/switch-hm
              patchShebangs checkout/switch-hm
              cp ${privateRoot}/tests/switch-hm-test.py checkout/tests/switch-hm-test.py
              cp ${privateRoot}/setup checkout/setup
              cp ${privateRoot}/verify-configs checkout/verify-configs
              cp ${privateRoot}/verify-kanata-configs checkout/verify-kanata-configs
              cp ${privateRoot}/edit-secret checkout/edit-secret
              cp ${privateRoot}/update-masterkeys checkout/update-masterkeys
              cp ${privateRoot}/takeover-host checkout/takeover-host
              cp ${privateRoot}/switch checkout/switch
              cp ${privateRoot}/switch-darwin checkout/switch-darwin
              chmod +x checkout/{setup,verify-configs,verify-kanata-configs,edit-secret,update-masterkeys,takeover-host,switch,switch-darwin}
              patchShebangs checkout
              cp ${privateRoot}/tests/flake-root-test.py checkout/tests/flake-root-test.py
              python3 checkout/tests/switch-hm-test.py -v
              python3 checkout/tests/flake-root-test.py -v
              touch $out
            '';
          }
          // privateOutputs.checks
        );
    devShells.default = pkgs.mkShell {
      shellHook = ''
        export NIX_CONFIG_DEV_SHELL=1
        # agenix edit runs under `set -u` and requires EDITOR. Keep a
        # user-chosen editor; otherwise use a store-pinned vim, for which
        # agenix disables swap/undo/viminfo files holding the plaintext.
        if [ -z "''${EDITOR:-}" ]; then
          export EDITOR=${pkgs.vim}/bin/vim
        fi
      '';
      packages = with pkgs; [
        agenix-rekey
        (callPackage ../pkg/resock/default.nix { })
        age
        age-plugin-tpm
        nixfmt
        qrencode
        wireguard-tools
        # inputs.json2nix.packages."${system}".json2nix
      ] ++ lib.optionals stdenv.hostPlatform.isLinux [ util-linux ];
    };
  }
)
