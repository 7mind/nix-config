{
  inputs = {
    # nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    # nixpkgs.url = "github:LunNova/nixpkgs/push-nmzswnymunon";

    flake-utils.url = "github:numtide/flake-utils";

    lanzaboote.url = "github:nix-community/lanzaboote";
    lanzaboote.inputs.nixpkgs.follows = "nixpkgs";

    crane.url = "github:ipetkov/crane";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

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

    smind = {
      url = "github:7mind/7mind-nix/master";
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

    nix-apple-fonts = {
      url = "github:braindefender/nix-apple-fonts";
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
      # gitlab links are broken on recent Nix https://github.com/NixOS/nix/issues/9161
      # and mac-app-util depends on a gitlab input for iterate/iterate package
      # : this fork contains a fixup commit for the gitlab url
      inputs.cl-nix-lite.url = "github:verymucho/cl-nix-lite/?ref=1b7fe99434067be93399d73cc747c6012b768584";
    };

    vicinae-extensions = {
      url = "github:vicinaehq/extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    claude-code-sandbox = {
      url = "github:neko-kai/claude-code-sandbox";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
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

    determinate = {
      url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
    };

    kanata-switcher = {
      url = "github:7mind/kanata-switcher/persistent-daemon";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    noctalia = {
      url = "github:noctalia-dev/noctalia-shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";

    fractal = {
      url = "git+https://gitlab.gnome.org/pshirshov/fractal.git?ref=wip/full-patchset";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ComfyUI packaged with pre-built wheels for CUDA / ROCm / Intel XPU.
    # Used on vm (Arc Pro B70 via XPU/oneAPI), pavel-am5 (W7900 via ROCm),
    # and pavel-fw (5070 via CUDA).
    #
    # We deliberately do NOT set `inputs.nixpkgs.follows = "nixpkgs"` here —
    # the flake's overlay vendors Python deps (gradio, comfyui-manager,
    # facexlib, timm, mss) whose nixpkgs versions drift past the wheels'
    # compatibility window on commits after ~2026-04-23. Letting comfyui-nix
    # use its own `flake.lock`-pinned nixpkgs keeps us on the snapshot the
    # upstream maintainer tested the wheels against (currently nixos-unstable
    # `c0b0e0fd` / 2025-12-28). When comfyui-nix bumps its lock with new
    # wheels, our `nix flake update` picks it up; until then we sit on a
    # known-good closure.
    comfyui-nix = {
      url = "github:utensils/comfyui-nix";
    };

    # zimt — multi-model image-generation REPL + web UI, pre-built per
    # backend (xpu / cuda / rocm / cpu). Used on vm (Arc Pro B70 via the
    # XPU backend). Like comfyui-nix, we deliberately do NOT make zimt
    # follow our nixpkgs: the flake vendors a large stack of pip wheels
    # (torch+IPEX, diffusers, transformers, fastapi …) whose
    # compatibility window tracks zimt's own pinned nixpkgs commit.
    # Letting it drift onto our nixpkgs would break the wheel build.
    zimt = {
      url = "github:pshirshov/zimt";
    };

    # CodeGraph — semantic code-intelligence MCP server for AI agents.
    # Pinned to the open PR (colbymchenry/codegraph#331) that adds the
    # flake; bump to upstream once it's merged.
    codegraph = {
      url = "github:uxtechie/codegraph/implement-nix-flake-support";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # markdown-ledger MCP server + extensible LLM prompt/skill assets
    # (ledger.packages.<system>.ledger-mcp, ledger.llmAssets).
    ledger = {
      url = "github:7mind/cq";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = inputs@{ self, ... }:
    let
      globals = import ./globals.nix;
      hosts-public = import ./hosts.nix;
      hosts-private = globals.import_if_exists_or ./private/hosts.nix ({ ... }: {
        nixos = [ ];
        darwin = [ ];
      });
      builders = {
        make-nixos-x86_64 = globals.make-nixos-x86_64 { inherit inputs; inherit self; };
        make-nixos-aarch64 = globals.make-nixos-aarch64 { inherit inputs; inherit self; };
        make-darwin-aarch64 = globals.make-darwin-aarch64 { inherit inputs; inherit self; };
      };
    in
    {
      inherit globals; # this makes this flake reusable by other flakes

      nixosConfigurations = builtins.listToAttrs ((hosts-public builders).nixos ++ (hosts-private builders).nixos);

      darwinConfigurations = builtins.listToAttrs ((hosts-public builders).darwin ++ (hosts-private builders).darwin);

      # Default agenix-rekey for all hosts
      agenix-rekey = inputs.agenix-rekey.configure {
        userFlake = self;
        nixosConfigurations = self.nixosConfigurations // self.darwinConfigurations;
      };

      # Per-host agenix-rekey configurations for selective rekeying
      agenix-rekey-hosts = builtins.mapAttrs
        (name: _:
          inputs.agenix-rekey.configure {
            userFlake = self;
            nixosConfigurations = { ${name} = (self.nixosConfigurations // self.darwinConfigurations).${name}; };
          }
        )
        (self.nixosConfigurations // self.darwinConfigurations);

      # Host metadata for setup script
      hostMeta =
        let
          allConfigs = self.nixosConfigurations // self.darwinConfigurations;
          extractMeta = name: cfg:
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
    } // inputs.flake-utils.lib.eachDefaultSystem (system: rec {
      pkgs = import inputs.nixpkgs {
        localSystem = system;
        overlays = [ inputs.agenix-rekey.overlays.default ];
      };
      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          # Plain `agenix` can't see host pubkeys from our `private/` git
          # submodule without `--extra-flake-params '?submodules=1'`; without
          # it, recipients resolve to junk and rage fails with
          # "Invalid recipient 'age'". Wrap it so the flag is implicit.
          (writeShellScriptBin "agenix" ''
            exec ${agenix-rekey}/bin/agenix --extra-flake-params '?submodules=1' "$@"
          '')
          (callPackage ./pkg/resock/default.nix { })
          age-plugin-tpm
          nixfmt
          qrencode
          wireguard-tools
          # inputs.json2nix.packages."${system}".json2nix
        ];
      };
    });

}
