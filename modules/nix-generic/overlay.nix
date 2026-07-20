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
