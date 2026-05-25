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
