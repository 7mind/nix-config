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
        overrideVtkDependencies = vtk: vtk.override {
          gdal = final.gdalMinimal;
          pdal = final.pdal;
        };
        patchVtk = vtk: (overrideVtkDependencies vtk).overrideAttrs (old: {
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

      # Backport nixpkgs #540826. The test writes its .gmac cache through the
      # netCDF driver, which the minimal build intentionally omits.
      gdalMinimal = prev.gdalMinimal.overrideAttrs (old: {
        disabledTests = (old.disabledTests or [ ]) ++ [
          "test_zarr_read_simple_sharding"
        ];
      });

      # PDAL 2.9.3 predates GDAL 3.13's const-qualified metadata API.
      pdal = prev.pdal.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (prev.fetchpatch {
            url = "https://github.com/PDAL/PDAL/commit/eb7220a2447c5b3d208d7ef0a76c61a17a5b21da.patch";
            hash = "sha256-WJ7PeCkSl+S+qURa1X3Z6D6LiPpvIXWmEap4XcYq9bk=";
          })
        ];
      });

      # VTK creates private minimal GDAL and PDAL packages, so pass the patched
      # packages explicitly rather than relying on top-level propagation.
      vtk = patchVtk prev.vtk;

      # Work around Python package regressions after nixpkgs update.
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (python-final: python-prev: {
          # FreeCAD uses the Python-enabled VTK variant, which has its own
          # private minimal GDAL and PDAL packages.
          vtk = overrideVtkDependencies python-prev.vtk;

          telethon = python-prev.telethon.overridePythonAttrs (old: {
            disabled = false;
            patches = [ ];
            disabledTests = (old.disabledTests or [ ]) ++ [
              "test_sync_acontext"
            ];
          });

          # web3's test-only py-evm dependency is archived and disabled on
          # Python 3.14. Trezor needs web3 at runtime, not its EVM test backend.
          # pyunormalize remains a declared runtime dependency in its wheel.
          web3 = python-prev.web3.overridePythonAttrs (old: {
            dependencies = old.dependencies ++ [ python-final.pyunormalize ];
            doCheck = false;
            nativeCheckInputs = [ ];
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
