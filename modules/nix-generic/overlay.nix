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

      mistral-vibe = prev.mistral-vibe.overrideAttrs (old: {
        nativeBuildInputs =
          (old.nativeBuildInputs or [ ])
          ++ [ prev.python3Packages.pythonRelaxDepsHook ];
        pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "cryptography" ];
        propagatedBuildInputs =
          (old.propagatedBuildInputs or [ ])
          ++ (with prev.python3Packages; [
            cachetools
            markdownify
          ]);
        disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [ "tests/e2e/" ];
      });

      # Work around Python package regressions after nixpkgs update.
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (python-final: python-prev: {
          telethon = python-prev.telethon.overridePythonAttrs (_: {
            patches = [ ];
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
