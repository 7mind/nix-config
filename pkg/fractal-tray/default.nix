{ lib
, fractal
, rustPlatform
, dbus
}:

let
  trayModule = ./tray.rs;
  cargoPatch = ./cargo.patch;
  cargoLockPatch = ./cargo-lock.patch;
  sourcePatch = ./source.patch;
  cargoPatches = [ cargoPatch cargoLockPatch ];
  allPatches = cargoPatches ++ [ sourcePatch ];
in
fractal.overrideAttrs (old: {
  pname = "fractal-tray";

  patches = (old.patches or []) ++ allPatches;

  postPatch = (old.postPatch or "") + ''
    # Add tray module
    cp ${trayModule} src/tray.rs
  '';

  # Need to update cargo vendor hash since we added ksni dependency
  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit (old) src;
    patches = cargoPatches;
    hash = "sha256-N1pjx3O0fJ67sMstTzk/TIuBAVlzEuaz/dHNha8E1BA=";
  };

  buildInputs = old.buildInputs ++ [ dbus ];

  meta = old.meta // {
    description = old.meta.description + " (with system tray support)";
  };
})
