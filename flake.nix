{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    hyprwhspr = {
      url = "github:goodroot/hyprwhspr/v1.49.2";
      flake = false;
    };

    flake-utils.url = "github:numtide/flake-utils";

    ponygirls = {
      url = "github:7mind/ponygirls";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    f4 = {
      url = "github:unxed/f4";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    lanzaboote.url = "github:nix-community/lanzaboote";
    lanzaboote.inputs.nixpkgs.follows = "nixpkgs";

    crane.url = "github:ipetkov/crane";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

    mqtt-controller = {
      url = "github:pshirshov/mqtt-controller";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.crane.follows = "crane";
      inputs.rust-overlay.follows = "rust-overlay";
    };

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-vscode-extensions.url = "github:nix-community/nix-vscode-extensions";
    nix-vscode-extensions.inputs.nixpkgs.follows = "nixpkgs";

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
      inputs.darwin.follows = "darwin";
    };

    agenix-rekey = {
      url = "github:oddlama/agenix-rekey";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pylontech = {
      url = "github:pshirshov/mqtt-pylontech";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    qendercore-adapter = {
      url = "github:pshirshov/mqtt-qendercore";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    mqtt-spc = {
      url = "github:pshirshov/mqtt-spc";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    ecoflow-mqtt = {
      url = "github:pshirshov/ecoflow-mqtt";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-apple-fonts = {
      # Fork of braindefender/nix-apple-fonts fixing evaluation against nixpkgs
      # >= 25.11 (removed lib.fold, reached via snowfall-lib). Upstream PR:
      # https://github.com/braindefender/nix-apple-fonts/pull/1 — switch back once merged.
      url = "github:autopeasant/nix-apple-fonts";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    darwin = {
      url = "github:nix-darwin/nix-darwin/master"; # master for nixpkgs-unstable
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # https://github.com/LnL7/nix-darwin/issues/214
    mac-app-util = {
      url = "github:hraban/mac-app-util";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    vicinae-extensions = {
      url = "github:vicinaehq/extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    browservice = {
      url = "github:pshirshov/browservice";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    plasma-manager = {
      url = "github:pjones/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    kanata-switcher = {
      url = "github:7mind/kanata-switcher/persistent-daemon";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    classic-app-switcher = {
      url = "github:neko-kai/classic-app-switcher";
      flake = false;
    };

    touchpad-gesture-customization-app-expose = {
      url = "github:7mind/touchpad-gesture-customization-app-expose";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    noctalia = {
      url = "github:noctalia-dev/noctalia-shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Track `develop`: the latest release (= `main`) predates nixpkgs 26.11's
    # removal of `stdenv.hostPlatform.linux-kernel`, so its bootloader module
    # aborts evaluation with `attribute 'linux-kernel' missing` / `buildDTBs
    # missing` on our unstable (26.11) nixpkgs. `develop` carries the 26.11
    # compatibility fixes (PRs #198, #199). Move back to a pinned release once
    # one ships with those changes.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/develop";

    fractal = {
      url = "git+https://gitlab.gnome.org/pshirshov/fractal.git?ref=wip/full-patchset";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # zimt — multi-model image-gen REPL + web UI, pre-built per backend
    # (xpu/cuda/rocm/cpu). Used on vm (Arc Pro B70, XPU). Deliberately does
    # NOT follow our nixpkgs: it vendors pip wheels (torch+IPEX, diffusers,
    # transformers, fastapi …) whose compatibility window tracks zimt's own
    # pinned nixpkgs; drifting breaks the wheel build.
    zimt = {
      url = "github:pshirshov/zimt";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    # Legacy github:7mind/cq input removed. Replacement is ../cq4; not wired yet.

    # wanbond — resilient WAN-bonding tunnel with adaptive FEC (repo renamed
    # from "fecalia"). Exposes packages.<system>.default = the wanbond binary.
    # Tracks main. Used by the mobile-office edge (pi-mo) and its concentrators
    # (raspi5l primary, o2 backup) — see modules/nixos/wanbond.nix (private).
    wanbond = {
      url = "github:7mind/wanbond/main";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs =
    inputs@{ self, ... }:
    let
      globals = import ./globals.nix;
      hosts-public = import ./hosts.nix;
      hosts-private = globals.import_if_exists_or ./private/hosts.nix (
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
    in
    {
      inherit globals; # this makes this flake reusable by other flakes

      nixosConfigurations = builtins.listToAttrs (
        (hosts-public builders).nixos ++ (hosts-private builders).nixos
      );

      darwinConfigurations = builtins.listToAttrs (
        (hosts-public builders).darwin ++ (hosts-private builders).darwin
      );

      homeConfigurations = builtins.listToAttrs (
        (hosts-public builders).home ++ ((hosts-private builders).home or [ ])
      );

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
          (globals.import_if_exists_or ./private/flake-outputs.nix (_: {
            overlays = [ ];
            packages = { };
            checks = { };
          }))
            { inherit pkgs; };
        pkgs = import inputs.nixpkgs {
          localSystem = system;
          overlays = [
            inputs.agenix-rekey.overlays.default
            (import ./pkg/openlinkhub/overlay.nix)
          ]
          ++ privateOutputs.overlays;
        };
      in
      {
        inherit pkgs;
        packages = {
          home-manager-cli = inputs.home-manager.packages.${system}.default;
        }
        // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
          hyprwhspr = pkgs.callPackage ./pkg/hyprwhspr { src = inputs.hyprwhspr; };
        }
        // privateOutputs.packages;
        checks =
          inputs.nixpkgs.lib.optionalAttrs
            (builtins.elem system [
              "x86_64-linux"
              "aarch64-linux"
            ])
            (
              
          {
                home-configurations =
                  let
                    capabilities = import ./tests/home-host-capabilities.nix {
                      inherit pkgs;
                      lib = pkgs.lib;
                    };
                    contexts = import ./tests/home-context.nix { flake = self; };
                    explicitModules = import ./tests/home-from-modules.nix { flake = self; };
                    darwinModules = import ./tests/home-from-modules-darwin.nix { flake = self; };
                    credentials = import ./tests/dev-llm-credentials.nix { flake = self; };
                  in
                  assert builtins.deepSeq [ capabilities contexts explicitModules darwinModules credentials ] true;
                  pkgs.runCommand "home-configurations" { } "touch $out";
                switch-hm = pkgs.runCommand "switch-hm-test" {
                  nativeBuildInputs = [ pkgs.bash pkgs.git pkgs.python3 ]
                    ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.util-linux ];
                } ''
                  mkdir -p checkout/tests
                  cp ${./switch-hm} checkout/switch-hm
                  chmod +x checkout/switch-hm
                  patchShebangs checkout/switch-hm
                  cp ${./tests/switch-hm-test.py} checkout/tests/switch-hm-test.py
                  python3 checkout/tests/switch-hm-test.py -v
                  touch $out
                '';
                home-shell = import ./tests/home-shell.nix { inherit pkgs; home-manager = inputs.home-manager; };
                nix-access-tokens = import ./tests/nix-access-tokens.nix { inherit pkgs; home-manager = inputs.home-manager; };
                gnome-extensions = import ./tests/gnome-extensions.nix { inherit pkgs inputs; home-manager = inputs.home-manager; };
                asterisk-linphone-fallback = import ./tests/asterisk-linphone-fallback.nix { inherit pkgs; };
                flexisip-file-transfer = import ./tests/flexisip.nix { inherit pkgs; };
                openlinkhub = import ./tests/openlinkhub.nix { inherit pkgs; };
                searxng = import ./tests/searxng.nix { inherit pkgs; };
              }
              // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
                hyprwhspr = import ./tests/hyprwhspr.nix {
                  inherit pkgs;
                  package = self.packages.${system}.hyprwhspr;
                };
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
            # Plain `agenix` can't see host pubkeys from our `private/` git
            # submodule without `--extra-flake-params '?submodules=1'`; without
            # it, recipients resolve to junk and rage fails with
            # "Invalid recipient 'age'". Wrap it so the flag is implicit.
            (writeShellScriptBin "agenix" ''
              exec ${agenix-rekey}/bin/agenix --extra-flake-params '?submodules=1' "$@"
            '')
            (callPackage ./pkg/resock/default.nix { })
            age
            age-plugin-tpm
            nixfmt
            qrencode
            wireguard-tools
            # inputs.json2nix.packages."${system}".json2nix
          ] ++ lib.optionals stdenv.hostPlatform.isLinux [ util-linux ];
        };
      }
    );

}
