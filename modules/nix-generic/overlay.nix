{ pkgs, ... }:

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

      # Update codex: 0.92.0 -> 0.111.0
      # Uses importCargoLock instead of fetchCargoVendor because a git
      # dependency (rules_rust) contains Cargo.toml files with unstable
      # features that break fetchCargoVendor's cargo metadata invocation.
      codex = prev.codex.overrideAttrs (old: rec {
        version = "0.111.0";
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ prev.pkg-config ];
        buildInputs = (old.buildInputs or [ ]) ++ [ prev.libcap ];
        src = prev.fetchFromGitHub {
          owner = "openai";
          repo = "codex";
          tag = "rust-v${version}";
          hash = "sha256-hdR70BhiMg9G/ibLCeHnRSY3PcGZDv0vnqBCbzSRD6I=";
        };
        sourceRoot = "${src.name}/codex-rs";
        cargoDeps = prev.rustPlatform.importCargoLock {
          lockFile = "${src}/codex-rs/Cargo.lock";
          outputHashes = {
            "crossterm-0.28.1" = "sha256-6qCtfSMuXACKFb9ATID39XyFDIEMFDmbx6SSmNe+728=";
            "nucleo-0.5.0" = "sha256-Hm4SxtTSBrcWpXrtSqeO0TACbUxq3gizg1zD/6Yw/sI=";
            "ratatui-0.29.0" = "sha256-HBvT5c8GsiCxMffNjJGLmHnvG77A6cqEL+1ARurBXho=";
            "runfiles-0.1.0" = "sha256-uJpVLcQh8wWZA3GPv9D8Nt43EOirajfDJ7eq/FB+tek=";
            "tokio-tungstenite-0.28.0" = "sha256-hJAkvWxDjB9A9GqansahWhTmj/ekcelslLUTtwqI7lw=";
            "tungstenite-0.27.0" = "sha256-AN5wql2X2yJnQ7lnDxpljNw0Jua40GtmT+w3wjER010=";
          };
        };
      });

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

          construct-classes = python-prev.construct-classes.overridePythonAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              substituteInPlace pyproject.toml \
                --replace-fail "uv_build>=0.8.13,<0.10.0" "uv_build>=0.8.13,<0.11.0"
            '';
          });
        })
      ];
    })
  ];
}
