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

        # dirty workaround: module inclusions trigger rebuilds we want to avoid
        generic-linux-module = import ./modules/nixos/env-settings-linux.nix;
      };


      cfg-platform =
        if cfg-meta.isLinux then {
          generator = inputs.nixpkgs.lib.nixosSystem;

          flake-modules = smind-nixos-imports ++ [
            inputs.lanzaboote.nixosModules.lanzaboote
            inputs.home-manager.nixosModules.home-manager
            inputs.agenix.nixosModules.default
            inputs.agenix-rekey.nixosModules.default
            inputs.determinate.nixosModules.default
            inputs.kanata-switcher.nixosModules.default
            inputs.noctalia.nixosModules.default

            { nixpkgs.overlays = [
                inputs.nix-vscode-extensions.overlays.default
                inputs.rust-overlay.overlays.default
                (final: prev: {
                  # Two overrides on intel-compute-runtime:
                  # (1) Bump 26.14.37833.4 → 26.18.38308.1 (2026-05-12).
                  #     nixpkgs gmmlib is already 22.10.0 (the 26.18 pairing),
                  #     so no companion bump. Drop once nixpkgs passes 26.18.
                  # (2) Patch intel-graphics-compiler into the RPATH of the
                  #     Level Zero driver `libze_intel_gpu.so.1` (`drivers`
                  #     split output). Upstream postFixup only fixes RPATH on
                  #     the OpenCL ICD (`libigdrcl.so`), leaving the L0 driver
                  #     without IGC on any search path; NEO's runtime dlopen of
                  #     `libigdfcl.so.2`/`libigc.so.2` during eager device init
                  #     then fails via `abortUnrecoverable`
                  #     (`gmm_helper/resource_info.cpp:15`). This abort was
                  #     mis-attributed to `intel/compute-runtime#922` on this
                  #     host since ~2026-02 — verified: putting
                  #     `${intel-graphics-compiler}/lib` on LD_LIBRARY_PATH
                  #     yields clean `zeInit = 0x0`, device enumeration, and
                  #     USM allocations. Closing this packaging gap unbricks
                  #     Level Zero on Battlemage.
                  intel-compute-runtime = (prev.intel-compute-runtime.overrideAttrs (oldAttrs: rec {
                    version = "26.18.38308.1";
                    src = prev.fetchFromGitHub {
                      owner = "intel";
                      repo = "compute-runtime";
                      tag = version;
                      hash = "sha256-539TqwzPhclEpyxrwRB0DBLCAgM8JojdshvhNp0jeKU=";
                    };
                    postFixup = (oldAttrs.postFixup or "") + ''
                      for lib in "$drivers"/lib/libze_intel*.so* ; do
                        # symlinks have no headers — skip cleanly
                        [ -L "$lib" ] && continue
                        patchelf --set-rpath ${
                          prev.lib.makeLibraryPath [
                            prev.intel-gmmlib
                            prev.intel-graphics-compiler
                            prev.libva
                            prev.stdenv.cc.cc
                          ]
                        } "$lib"
                      done
                    '';
                  }));
                  # nixpkgs `intel-llvm` (PR #470035, merged April 2026)
                  # packaging bug: its merged output uses symlinkJoin +
                  # __structuredAttrs = true, which silently produces an empty
                  # $out (the lndir loop references $pathsPath that
                  # structuredAttrs doesn't populate the legacy way). Disable
                  # structuredAttrs on the merge step so $paths is a plain
                  # shell variable again. Verify:
                  # `ls $(nix eval --raw nixpkgs#intel-llvm.outPath)/bin`
                  # should list clang/clang++/clang-22 etc.
                  intel-llvm = (prev.intel-llvm.overrideScope (_: intelPrev: {
                    unwrapped = (intelPrev.unwrapped.override {
                      wrapCC = cc: prev.wrapCC (cc.overrideAttrs (old: {
                        passthru = (old.passthru or { }) // { langCC = true; };
                      }));
                    }).overrideAttrs (old: {
                      # LLVM detects x86_64-pc-linux-gnu from GCC, but Nix's
                      # compiler wrapper targets x86_64-unknown-linux-gnu.
                      # Libdevice passes LLVM's detected triple explicitly,
                      # which prevents the wrapper from adding libstdc++
                      # include paths.
                      cmakeFlags = old.cmakeFlags ++ [
                        (prev.lib.cmakeFeature "LLVM_HOST_TRIPLE" prev.stdenv.hostPlatform.config)
                        (prev.lib.cmakeFeature "LLVM_DEFAULT_TARGET_TRIPLE" prev.stdenv.hostPlatform.config)
                      ];
                      passthru = old.passthru // { langCC = true; };
                    });
                  })).overrideAttrs (old: {
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

                  # ollama with the GGML SYCL backend wired in for the
                  # Intel Arc Pro B70. Vendors the entire llama.cpp tree
                  # at the same commit as pkg/llama-cpp-sycl (073bb2c20),
                  # so both packages share kernel fixes and our MMVQ
                  # cherry-pick. Inherits the (overridden, see below)
                  # `ollama` for go-side tooling versions.
                  ollama-sycl = final.callPackage ./pkg/ollama-sycl/default.nix { };

                  # Stock ollama flavors (ollama/-cuda/-rocm/-vulkan) ride
                  # nixpkgs' own version (0.30.7), matching the in-container
                  # ollama-sycl server. The former 0.24.0 pin is retired: clean
                  # ollama < 0.30 lacks `llama/compat/`, which nixpkgs' postPatch
                  # (apply-patch.cmake, FetchContent llama.cpp) now requires —
                  # pinning back to 0.24.0 broke every flavor's patchPhase.
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
              ];
            }
          ];

          hm-modules = [
            inputs.mac-app-util.homeManagerModules.default
            # nix-darwin runs HM activation through sudo→launchctl asuser→sudo -u user.
            # TCC doesn't associate that process chain with the terminal emulator, so both the
            # App Management permission check and the rsync copyApps itself fail.
            # mac-app-util already handles Spotlight/Launchpad visibility via trampolines,
            # so copyApps is redundant.
            { targets.darwin.copyApps.enable = false; }
          ];
        };

      cfg-flakes = {
        pkgs7mind = inputs.smind.legacyPackages."${arch}";

        pylontech = inputs.pylontech.packages."${arch}";
        qendercore-adapter = inputs.qendercore-adapter;
        mqtt-spc = inputs.mqtt-spc;
        nix-apple-fonts.default = pkgs.callPackage "${inputs.nix-apple-fonts}/packages/apple-fonts/default.nix" {
          inputs = { };
          xorg.mkfontscale = pkgs.mkfontscale;
        };
        browservice.packages.${arch}.default =
          let
            original = inputs.browservice.packages.${arch}.default;
            runtimeLibs = with pkgs; [
              libx11
              libxcomposite
              libxcursor
              libxdamage
              libxext
              libxfixes
              libxi
              libxrandr
              libxrender
              libxscrnsaver
              libxtst
              libxcb
              libxshmfence
              libxkbcommon
              gtk3
              glib
              pango
              cairo
              gdk-pixbuf
              atk
              at-spi2-atk
              at-spi2-core
              dbus
              alsa-lib
              cups
              libdrm
              mesa
              libGL
              libGLU
              expat
              nspr
              nss
              udev
              libgbm
              fontconfig
              freetype
              zlib
              bzip2
            ];
            cefDllWrapper = original.cefDllWrapper.overrideAttrs (_: {
              buildInputs = runtimeLibs;
            });
          in
          original.overrideAttrs (_: {
            buildInputs = (with pkgs; [
              pango
              libx11
              libxcb
              poco
              libjpeg
              zlib
              openssl
            ]) ++ runtimeLibs;
            preBuild = ''
              mkdir -p cef/{Release,Resources,include,releasebuild/libcef_dll_wrapper}
              cp -r ${cefDllWrapper}/Release/* cef/Release/
              cp -r ${cefDllWrapper}/Resources/* cef/Resources/
              cp -r ${cefDllWrapper}/include/* cef/include/
              cp ${cefDllWrapper}/lib/libcef_dll_wrapper.a cef/releasebuild/libcef_dll_wrapper/

              pushd viceplugins/retrojsvice
              mkdir -p gen
              python3 gen_html_cpp.py > gen/html.cpp
              popd
            '';
            postFixup = ''
              patchelf --set-rpath "$out/lib:${pkgs.lib.makeLibraryPath runtimeLibs}" $out/bin/browservice-unwrapped
              if [ -f $out/lib/chrome-sandbox ]; then
                chmod 755 $out/lib/chrome-sandbox
              fi
            '';
            passthru.cefDllWrapper = cefDllWrapper;
          });
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
