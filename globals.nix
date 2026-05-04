rec {
  import_if_exists_or = path: default: if builtins.pathExists path then import path else default;
  import_if_exists = path: import_if_exists_or path { };

  smind-nixos-imports = builtins.concatLists [
    (import ./lib/_imports.nix)
    (import ./modules/generic/_imports.nix)
    (import ./modules/nix-generic/_imports.nix)
    (import ./modules/nixos/_imports.nix)
    (import ./roles/nixos/_imports.nix)

    (import_if_exists_or ./private/lib/_imports.nix [ ])
    (import_if_exists_or ./private/modules/generic/_imports.nix [ ])
    (import_if_exists_or ./private/modules/nix-generic/_imports.nix [ ])
    (import_if_exists_or ./private/modules/nixos/_imports.nix [ ])
    (import_if_exists_or ./private/roles/nixos/_imports.nix [ ])
  ];

  smind-darwin-imports = builtins.concatLists [
    (import ./lib/_imports.nix)
    (import ./modules/generic/_imports.nix)
    (import ./modules/nix-generic/_imports.nix)
    (import ./modules/darwin/_imports.nix)
    (import ./roles/darwin/_imports.nix)


    (import_if_exists_or ./private/lib/_imports.nix [ ])
    (import_if_exists_or ./private/modules/generic/_imports.nix [ ])
    (import_if_exists_or ./private/modules/nix-generic/_imports.nix [ ])
    (import_if_exists_or ./private/modules/darwin/_imports.nix [ ])
    (import_if_exists_or ./private/roles/darwin/_imports.nix [ ])
  ];

  smind-hm = {
    imports = builtins.concatLists [
      (import ./lib/_imports.nix)
      (import ./modules/generic/_imports.nix)
      (import ./modules/hm/_imports.nix)
      (import ./roles/hm/_imports.nix)

      (import_if_exists_or ./private/lib/_imports.nix [ ])
      (import_if_exists_or ./private/modules/generic/_imports.nix [ ])
      (import_if_exists_or ./private/modules/hm/_imports.nix [ ])
      (import_if_exists_or ./private/roles/hm/_imports.nix [ ])
    ];
  };

  make = { self, inputs, arch }: hostname:
    let
      pkgs = import inputs.nixpkgs {
        localSystem = arch;
        config.allowUnfree = true;
      };

      const = import ./config.nix;

      cfg-const = pkgs.lib.recursiveUpdate
        const.const
        (import_if_exists ./private/config.nix);


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
        isLinux = builtins.trace (arch) (pkgs.lib.hasSuffix "-linux" arch);
        isDarwin = pkgs.lib.hasSuffix "-darwin" arch;
        state-version-system = if isLinux then cfg-const.state-version-nixpkgs else cfg-const.state-version-darwin;

        # module inclusions trigger rebuilds we would like to avoid, so here is a dirty workaround
        generic-linux-module = import ./modules/nixos/env-settings-linux.nix;
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
            inputs.determinate.nixosModules.default
            inputs.kanata-switcher.nixosModules.default
            inputs.noctalia.nixosModules.default

            { nixpkgs.overlays = [
                inputs.nix-vscode-extensions.overlays.default
                inputs.rust-overlay.overlays.default
                (final: prev:
                let
                  # Shared override attrs for the ollama 0.21.0 → 0.23.0
                  # bump (referenced four times below for each
                  # accelerated variant: stock + cuda + rocm + vulkan).
                  ollamaBumpAttrs = {
                    version = "0.23.0";
                    src = prev.fetchFromGitHub {
                      owner = "ollama";
                      repo = "ollama";
                      tag = "v0.23.0";
                      hash = "sha256-VYaFCSqhIlJPJv1SUiNDgSzLqySK3NTfucdWA7IZaAk=";
                    };
                    # 0.23.0 added a `cmd/launch` test that npm-installs
                    # `@ollama/pi-web-search` — fails in the nix
                    # sandbox (no network). nixpkgs upstream's checkFlags
                    # only `-skip`s the 0.21.0-era tests by name.
                    # Disable Go-side checks entirely; the
                    # `versionCheckHook` (run via doInstallCheck=true,
                    # inherited from upstream) still verifies the
                    # built binary actually runs and reports its
                    # version.
                    doCheck = false;
                  };
                in {
                  claude-code = final.callPackage ./pkg/claude-code/package.nix { };
                  # The upstream nixpkgs `intel-llvm` (PR #470035, merged
                  # April 2026) has a packaging bug: its top-level merged
                  # output is built via symlinkJoin + __structuredAttrs = true,
                  # which silently produces an empty $out (the lndir loop
                  # references $pathsPath that structuredAttrs doesn't
                  # populate the legacy way). Override to disable
                  # structuredAttrs on the merge step so $paths becomes a
                  # plain shell variable again. Verified by running
                  # `ls $(nix eval --raw nixpkgs#intel-llvm.outPath)/bin`
                  # before/after — should list clang/clang++/clang-22 etc.
                  intel-llvm = prev.intel-llvm.overrideAttrs (old: {
                    __structuredAttrs = false;
                    paths = builtins.toString old.paths;
                    # The buildCommand still references `$pathsPath` (it
                    # `cat`s it inside the lndir loop), so `paths` must be
                    # in passAsFile alongside buildCommand.
                    passAsFile = [ "buildCommand" "paths" ];
                  });
                  # Intel oneMKL 2025.3.1 — newer than nixpkgs `mkl@2023.1.0`
                  # and ABI-matched to intel-llvm@unstable-2025-11-14
                  # (libsycl.so.8). Sister-package, not an override of
                  # `mkl`, so the rest of nixpkgs (numpy/scipy/octave)
                  # keeps using 2023.1.
                  mkl-sycl = final.callPackage ./pkg/mkl-sycl/default.nix { };

                  # llama.cpp built with the SYCL backend, pinned to the same
                  # upstream commit ollama 0.21 vendors. Linux-only — needs
                  # intel-llvm + intel-compute-runtime + level-zero, none of
                  # which exist on Darwin.
                  llama-cpp-sycl = final.callPackage ./pkg/llama-cpp-sycl/default.nix {
                    mkl = final.mkl-sycl;
                  };

                  # ollama with the GGML SYCL backend grafted in for the
                  # Intel Arc Pro B70. Inherits the (overridden, see
                  # below) `ollama` and vendors `ggml-sycl/` from the
                  # same upstream commit ollama pins.
                  ollama-sycl = final.callPackage ./pkg/ollama-sycl/default.nix { };

                  # Bump every flavor of stock nixpkgs ollama from the
                  # currently-pinned 0.21.0 to 0.23.0 — nixpkgs hasn't
                  # bumped yet but upstream is on 0.23.0 since 2026-05-03.
                  # We need this so:
                  #   - The host-side `ollama` CLI on `vm` matches the
                  #     in-container `ollama-sycl` server (no
                  #     "client version is 0.21.0" warning).
                  #   - Other hosts (pavel-am5/pavel-fw using
                  #     ollama-vulkan, kai-am5 using ollama-rocm,
                  #     kai-fw using ollama-vulkan) all get the same
                  #     fixes ollama-sycl gets.
                  # NOTE: `ollama`, `ollama-cuda`, `ollama-rocm`,
                  # `ollama-vulkan` are *separate* callPackage
                  # instantiations of the same package.nix with
                  # different `acceleration` arguments — overriding
                  # `ollama` does NOT propagate to the accelerated
                  # variants (each variant gets its own fixed-output
                  # derivation). Override every variant inline.
                  # vendorHash unchanged — go.mod/go.sum stable across
                  # the 39 commits between 0.21.0 and 0.23.0
                  # (or proxyVendor=true makes it invariant).
                  ollama         = prev.ollama.overrideAttrs         (_: ollamaBumpAttrs);
                  ollama-cuda    = prev.ollama-cuda.overrideAttrs    (_: ollamaBumpAttrs);
                  ollama-rocm    = prev.ollama-rocm.overrideAttrs    (_: ollamaBumpAttrs);
                  ollama-vulkan  = prev.ollama-vulkan.overrideAttrs  (_: ollamaBumpAttrs);
                  vscode-marketplace = prev.vscode-marketplace // {
                    anthropic = prev.vscode-marketplace.anthropic // {
                      claude-code = prev.vscode-marketplace.anthropic.claude-code.overrideAttrs (old: {
                        postInstall = ''
                          mkdir -p "$out/$installPrefix/resources/native-binary"
                          rm -f "$out/$installPrefix/resources/native-binary/claude"*
                          ln -s "${final.claude-code}/bin/claude" "$out/$installPrefix/resources/native-binary/claude"
                        '';
                      });
                    };
                  };
                })
              ];
            }
          ];

          hm-modules = [
            inputs.plasma-manager.homeModules.plasma-manager
            inputs.niri.homeModules.config
            inputs.noctalia.homeModules.default
          ];
        } else {
          generator = inputs.darwin.lib.darwinSystem;

          flake-modules = smind-darwin-imports ++ [
            inputs.mac-app-util.darwinModules.default
            inputs.home-manager.darwinModules.home-manager
            inputs.agenix.darwinModules.default
            inputs.agenix-rekey.nixosModules.default
            inputs.determinate.darwinModules.default
            { nixpkgs.overlays = [
                inputs.nix-vscode-extensions.overlays.default
                inputs.rust-overlay.overlays.default
                (final: prev: {
                  claude-code = final.callPackage ./pkg/claude-code/package.nix { };
                  vscode-marketplace = prev.vscode-marketplace // {
                    anthropic = prev.vscode-marketplace.anthropic // {
                      claude-code = prev.vscode-marketplace.anthropic.claude-code.overrideAttrs (old: {
                        postInstall = ''
                          mkdir -p "$out/$installPrefix/resources/native-binary"
                          rm -f "$out/$installPrefix/resources/native-binary/claude"*
                          ln -s "${final.claude-code}/bin/claude" "$out/$installPrefix/resources/native-binary/claude"
                        '';
                      });
                    };
                  };
                })
              ];
            }
          ];

          hm-modules = [

          ];
        };

      cfg-flakes = {
        pkgs7mind = inputs.smind.legacyPackages."${arch}";

        pylontech = inputs.pylontech.packages."${arch}";
        qendercore-adapter = inputs.qendercore-adapter;
        mqtt-spc = inputs.mqtt-spc;
        nix-apple-fonts = inputs.nix-apple-fonts.packages."${arch}";
        browservice = inputs.browservice;
        fractal = inputs.fractal.packages."${arch}";
      };

      cfg-hm-modules = cfg-platform.hm-modules ++ [
        { home.stateVersion = cfg-const.state-version-hm; }

        inputs.agenix.homeManagerModules.default
        inputs.agenix-rekey.homeManagerModules.default
      ];

      cfg-args = {
        inherit smind-hm;
        inherit cfg-meta;
        inherit cfg-flakes;
        inherit cfg-packages;
        inherit cfg-hm-modules;
        inherit inputs;
        inherit cfg-const;
        inherit import_if_exists;
        inherit import_if_exists_or;
      };
      specialArgs = cfg-args // {
        specialArgsSelfRef = cfg-args;
        inherit (inputs) nixos-raspberrypi;
      };
    in
    {
      name = "${hostname}";
      value = cfg-platform.generator
        {
          inherit specialArgs;
          modules = cfg-platform.flake-modules ++ [
            { nixpkgs.hostPlatform = arch; }
            { system.stateVersion = cfg-meta.state-version-system; }
            (cfg-args.import_if_exists ./hosts/${hostname}/cfg-${hostname}.nix)
            (cfg-args.import_if_exists ./private/hosts/${hostname}/cfg-${hostname}.nix)
          ];
        };
    };

  make-nixos-x86_64 = { inputs, self }: (make {
    inherit inputs;
    inherit self;
    arch = "x86_64-linux";
  });

  make-nixos-aarch64 = { inputs, self }: (make {
    inherit inputs;
    inherit self;
    arch = "aarch64-linux";
  });

  make-darwin-aarch64 = { inputs, self }: (make {
    inherit inputs;
    inherit self;
    arch = "aarch64-darwin";
  });
}
