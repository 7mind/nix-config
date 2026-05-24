{ pkgs, cfg-meta, ... }:

{
  nixpkgs.overlays = [
    (final: prev: {
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

      codex =
        let
          version = "0.126.0-alpha.3";
          binaryAssets = {
            aarch64-darwin = {
              asset = "codex-aarch64-apple-darwin.tar.gz";
              hash = "sha256-8lUS1OsGc+uBFsiFpRNTHqunFpDwvS24GwOJwnnrGGg=";
            };
            aarch64-linux = {
              asset = "codex-aarch64-unknown-linux-musl.tar.gz";
              hash = "sha256-DzghkSOuGk7Qh9l7QDYgdjcCWCw72yGTygXoo5UZ9C0=";
            };
            x86_64-darwin = {
              asset = "codex-x86_64-apple-darwin.tar.gz";
              hash = "sha256-zxpNcsOd3WGXrb8qkrwidI+kJpEZzuZCwJIUVn5SzBQ=";
            };
            x86_64-linux = {
              asset = "codex-x86_64-unknown-linux-musl.tar.gz";
              hash = "sha256-1Zik0ukwfyZprt+i+WiBZF4P5bHv+igT+svrUxyspLM=";
            };
          };
          system = prev.stdenv.hostPlatform.system;
        in
        if prev.lib.hasAttr system binaryAssets then
          let
            binaryAsset = binaryAssets.${system};
          in
          prev.stdenvNoCC.mkDerivation {
            pname = "codex";
            inherit version;

            src = prev.fetchurl {
              url = "https://github.com/openai/codex/releases/download/rust-v${version}/${binaryAsset.asset}";
              hash = binaryAsset.hash;
            };

            nativeBuildInputs = [
              prev.installShellFiles
              prev.makeBinaryWrapper
            ];

            dontUnpack = true;
            dontConfigure = true;
            dontBuild = true;

            installPhase = ''
              runHook preInstall
              tar -xzf "$src"
              install -Dm755 codex-* "$out/bin/codex"
              runHook postInstall
            '';

            postInstall = prev.lib.optionalString (prev.stdenv.buildPlatform.canExecute prev.stdenv.hostPlatform) ''
              installShellCompletion --cmd codex \
                --bash <($out/bin/codex completion bash) \
                --fish <($out/bin/codex completion fish) \
                --zsh <($out/bin/codex completion zsh)
            '';

            postFixup = ''
              wrapProgram "$out/bin/codex" --prefix PATH : ${
                prev.lib.makeBinPath ([ prev.ripgrep ] ++ prev.lib.optionals prev.stdenv.hostPlatform.isLinux [ prev.bubblewrap ])
              }
            '';

            doInstallCheck = prev.stdenv.buildPlatform.canExecute prev.stdenv.hostPlatform;
            nativeInstallCheckInputs = [ prev.versionCheckHook ];

            meta = prev.codex.meta // {
              mainProgram = "codex";
            };

            passthru = prev.codex.passthru or { };
          }
        else
          prev.codex;

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

      # Work around Python package regressions after nixpkgs update.
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (python-final: python-prev: {
          telethon = python-prev.telethon.overridePythonAttrs (_: {
            patches = [ ];
          });

          # mypy >=1.x changed --revealed-type output: `builtins.int` → `int`
          # (PEP 585). eth-utils 6.0.0 tests still expect the old strings.
          # Tests are purely about mypy output format, not eth-utils behaviour.
          eth-utils = python-prev.eth-utils.overridePythonAttrs (old: {
            disabledTests = (old.disabledTests or [ ]) ++ [
              "test_type_inference"
            ];
          });

          # jedi-language-server 0.46.0 pins jedi<0.20; nixpkgs is on 0.20.x.
          # Minor jedi bump, API-compatible — relax the constraint.
          jedi-language-server = python-prev.jedi-language-server.overridePythonAttrs (old: {
            pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "jedi" ];
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
