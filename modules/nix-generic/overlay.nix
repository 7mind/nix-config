{ pkgs, cfg-meta, ... }:

{
  nixpkgs.overlays = [
    (import ../../pkg/openlinkhub/overlay.nix)
    (final: prev: {
      # Used by shared hm modules (modules/hm/tmux.nix) on both Linux and Darwin,
      # so it lives in the shared overlay, not modules/nixos/overlay.nix.
      fastfetch-minimal = prev.callPackage ../../pkg/fastfetch-minimal { };

      far2l-noui = prev.callPackage ../../pkg/far2l-noui { };
      flurry = prev.callPackage ../../pkg/flurry/package.nix { };
      jabracli = prev.callPackage ../../pkg/jabracli/package.nix { };

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

      # mcp-proxy requires mcp<2; keep its scope on the compatibility package.
      mcp-proxy = prev.mcp-proxy.override {
        python3Packages = prev.python3Packages.overrideScope (mcp-final: _: {
          mcp = mcp-final.mcp_1;
        });
      };

      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (python-final: python-prev: {
          mcp = python-prev.mcp.overridePythonAttrs (old: {
            version = "2.3.0";
            src = old.src.override {
              tag = "v2.3.0";
              hash = "sha256-CnXi78zYxm0/R4fON/DzRYMSDYM/XM/9SE3s+Cf1BR0=";
            };
            nativeCheckInputs = old.nativeCheckInputs ++ [
              (python-prev.blockbuster.overridePythonAttrs (blockbusterOld: {
                version = "1.5.29";
                nativeCheckInputs = blockbusterOld.nativeCheckInputs ++ [ python-prev.pytest-benchmark ];
                src = prev.fetchPypi {
                  pname = "blockbuster";
                  version = "1.5.29";
                  hash = "sha256-D9UHpKEV65Pt31gNegwp8KjvLUR97X+FPQz5qxz5eH0=";
                };
              }))
            ];
          });

          # Local MCP 1.x release, newer than nixpkgs' compatibility package.
          mcp_1 = python-final.callPackage ../../pkg/mcp-1 { };

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

          rich = python-prev.rich.overridePythonAttrs (old:
            prev.lib.optionalAttrs prev.stdenv.hostPlatform.isAarch64 {
              # The producer can finish before `head -1` closes the pipe, in
              # which case exit 0 is valid and the broken-pipe assertion races.
              disabledTests = (old.disabledTests or [ ]) ++ [
                "test_brokenpipeerror"
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

          python-matter-server =
            let
              skipZeroconf = pkg:
                pkg.overridePythonAttrs (old:
                  prev.lib.optionalAttrs prev.stdenv.hostPlatform.isAarch64 {
                    # test_server_start opens an IPv6 multicast socket;
                    # qemu-user and the nix sandbox return OSError 92.
                    disabledTests = (old.disabledTests or [ ]) ++ [
                      "test_server_start"
                    ];
                  }
                );
            in
            skipZeroconf python-prev.python-matter-server
            // {
              # preserve callPackage-style .override { withDashboard = false }
              # used by the dashboard bootstrap in nixpkgs' package.nix
              override = args: skipZeroconf (python-prev.python-matter-server.override args);
            };
        })
      ];
    })
  ];
}
