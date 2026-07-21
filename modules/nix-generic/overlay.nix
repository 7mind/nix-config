{ pkgs, cfg-meta, ... }:

{
  nixpkgs.overlays = [
    (final: prev:
      let
        # VTK 9.5.2 predates GDAL 3.13's const-qualified metadata API.
        vtkGdalConstPatch = prev.fetchpatch {
          url = "https://github.com/Kitware/VTK/commit/2395603fdddc40c29efc64c632ae98225ca2a58e.patch";
          hash = "sha256-Gcnt1JXWPkhfNLhtk9SXYqx/0cLkjO4xiRfR8YiaY8I=";
        };
        patchVtk = vtk: vtk.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ vtkGdalConstPatch ];
        });
      in
      {
      # Downgrade wireplumber to 0.5.12 to fix GNOME crash when switching
      # Bluetooth audio to handsfree/HSP/HFP profile.
      # See: https://github.com/NixOS/nixpkgs/issues/475202
      # wireplumber = prev.wireplumber.overrideAttrs (old: rec {
      #   version = "0.5.12";
      #   src = prev.fetchurl {
      #     url = "https://gitlab.freedesktop.org/pipewire/wireplumber/-/archive/${version}/wireplumber-${version}.tar.gz";
      #     hash = "sha256-DOXNSAh7xbVZ1+GpR+ngrbKptvHavZhK+AHzD7ul4Zw=";
      #   };
      # });

      # NOTE: claude-code and codex were vendored here; they now live in the cq
      # flake (inputs.cq.packages.<system>.{claude-code,codex}) and are consumed
      # directly by inputs.cq.homeManagerModules.dev-llm. Nothing else in this
      # config references pkgs.{claude-code,codex}, so no override remains here.

      # ripgrep's `misc::compressed_{brotli,lz4,zstd}` integration tests fail
      # with exit 2 / empty stderr when an aarch64 build runs under qemu-user
      # binfmt on an x86_64 remote builder (nix sees buildPlatform ==
      # hostPlatform == aarch64-linux, so we can't condition on canExecute).
      # The other 326 tests still run; skip just these three unconditionally
      # on aarch64-linux.
      ripgrep = prev.ripgrep.overrideAttrs (old: prev.lib.optionalAttrs prev.stdenv.hostPlatform.isAarch64 {
        checkFlags = (old.checkFlags or [ ]) ++ [
          "--skip=misc::compressed_brotli"
          "--skip=misc::compressed_lz4"
          "--skip=misc::compressed_zstd"
        ];
      });

      # bat's integration tests for --help, --list-languages, PAGER=bat handling and
      # --set-terminal-title assume that `less` is not found in $PATH during
      # `cargo test` (so that paging falls back to direct stdout). Under
      # qemu-user binfmt aarch64 emulation on an x86_64 builder, `less` becomes
      # resolvable, causing output to be sent to the pager child instead.
      # Skip the affected tests (matching the skips already present in nixpkgs'
      # bat package.nix for other pager tests).
      bat = prev.bat.overrideAttrs (old: prev.lib.optionalAttrs prev.stdenv.hostPlatform.isAarch64 {
        checkFlags = (old.checkFlags or [ ]) ++ [
          "--skip=basic_set_terminal_title"
          "--skip=env_var_pager_value_bat"
          "--skip=help_uses_valid_config"
          "--skip=help_works_with_invalid_config"
          "--skip=list_languages"
          "--skip=long_help"
          "--skip=short_help"
        ];
      });

      # Every polkit test enters a user and mount namespace through
      # os.unshare(CLONE_NEWUSER | CLONE_NEWNS). qemu-user binfmt returns EINVAL
      # for that call, so none of the test bodies run on the emulated aarch64
      # builder. Nix reports buildPlatform == hostPlatform == aarch64-linux in
      # this setup, so disable the suite for aarch64-linux.
      polkit = if prev.stdenv.hostPlatform.isAarch64
        then prev.polkit.override { doCheck = false; }
        else prev.polkit;

      # lsd uses pandoc only to render its Markdown man page. Keep the binary
      # and generated shell completions without pulling pandoc's Haskell build
      # graph into every host that installs lsd.
      lsd = prev.lsd.overrideAttrs (old: {
        nativeBuildInputs = prev.lib.remove prev.pandoc (old.nativeBuildInputs or [ ]);
        postInstall = ''
          installShellCompletion --cmd lsd \
            --bash $releaseDir/build/lsd-*/out/lsd.bash \
            --fish $releaseDir/build/lsd-*/out/lsd.fish \
            --zsh $releaseDir/build/lsd-*/out/_lsd
        '';
      });

      # tpm2-tools exposes a supported switch for omitting its pandoc-generated
      # man pages. fwupd depends on the tools, not their documentation.
      tpm2-tools = prev.tpm2-tools.override { enableManpages = false; };

      # CGAL 6.2 emits a non-null-terminated .debug_gdb_scripts section, which
      # LLVM 21's linker rejects during OpenSCAD's ThinLTO link.
      cgal = prev.cgal.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (prev.fetchpatch {
            name = "cgal-gdb-autoload-null-termination.patch";
            url = "https://github.com/CGAL/cgal/commit/eb2257df4da4c52c75fe384e803d9a6376057b8a.patch";
            stripLen = 1;
            hash = "sha256-3YMYX3/Ioiwk10ixNTRdYGNWrO5q7S9hDHOTcJRXBAk=";
          })
        ];
      });

      vtk = patchVtk prev.vtk;

      # Work around Python package regressions after nixpkgs update.
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (python-final: python-prev: {
          # web3's test-only py-evm dependency is archived and disabled on
          # Python 3.14. Trezor needs web3 at runtime, not its EVM test backend.
          # pyunormalize remains a declared runtime dependency in its wheel.
          web3 = python-prev.web3.overridePythonAttrs (old: {
            dependencies = old.dependencies ++ [ python-final.pyunormalize ];
            doCheck = false;
            nativeCheckInputs = [ ];
          });

          paho-mqtt = python-prev.paho-mqtt.overridePythonAttrs (old:
            prev.lib.optionalAttrs prev.stdenv.hostPlatform.isAarch64 {
              # These integration tests launch broker/client subprocesses whose
              # teardown timeout interrupts different clients under load.
              disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
                "tests/lib"
              ];
              disabledTests = (old.disabledTests or [ ]) ++ [
                "test_callback_v1_mqtt3"
                "test_callback_v2_mqtt3"
              ];
            });

          anyio = python-prev.anyio.overridePythonAttrs (old:
            prev.lib.optionalAttrs prev.stdenv.hostPlatform.isAarch64 {
              disabledTests = (old.disabledTests or [ ]) ++ [
                "test_keyboard_interrupt_does_not_resume_test"
              ];
            });

          websockets = python-prev.websockets.overridePythonAttrs (old:
            prev.lib.optionalAttrs prev.stdenv.hostPlatform.isAarch64 {
              # unittestCheckHook ignores disabledTests, so make these two
              # socket-error timing tests undiscoverable on aarch64.
              postPatch = (old.postPatch or "") + ''
                substituteInPlace tests/sync/test_connection.py \
                  --replace-fail "def test_writing_in_recv_events_fails" "def disabled_writing_in_recv_events_fails" \
                  --replace-fail "def test_writing_in_send_context_fails" "def disabled_writing_in_send_context_fails"
              '';
            });

          pillow = python-prev.pillow.overridePythonAttrs (_:
            prev.lib.optionalAttrs prev.stdenv.hostPlatform.isAarch64 {
              # Under qemu-user the Python interpreter aborts while pytest is
              # still collecting tests, before a narrower test can be named.
              doCheck = false;
              nativeCheckInputs = [ ];
            });

          # construct-classes = python-prev.construct-classes.overridePythonAttrs (old: {
          #   postPatch = (old.postPatch or "") + ''
          #     substituteInPlace pyproject.toml \
          #       --replace-fail "uv_build>=0.8.13,<0.9.0" "uv_build>=0.8.13,<0.11.0"
          #   '';
          # });
        })
      ];
    })
  ];
}
