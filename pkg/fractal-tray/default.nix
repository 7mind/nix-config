{ dbus
, fetchgit
, fractal
, libglycin
, rustPlatform
}:

let
  src = fetchgit {
    url = "https://gitlab.gnome.org/pshirshov/fractal.git";
    rev = "927ffeb436d03ec55aa8399a858ef1c760823a0c";
    hash = "sha256-CBjbQ0AsLESHejHqlYdb4Fu3dTX1oS2Q5x5AJtY3xzE=";
  };
in
fractal.overrideAttrs (old: {
  pname = "fractal-tray";

  version = "unstable-2026-01-20";
  inherit src;

  mesonBuildType = "debugoptimized";

  mesonFlags = (old.mesonFlags or [ ]) ++ [
    "-Db_lto=false"
  ];

  # Need to update cargo vendor hash since we added ksni dependency
  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit src;
    hash = "sha256-uULj/9ixqq9cGg7U1m4QnfTl6Hvpjx0nJPjWvF2rW2M=";
  };

  postPatch = (old.postPatch or "") + ''
    patchShebangs build-aux
  '';

  buildInputs = old.buildInputs ++ [ dbus libglycin ];

  meta = old.meta // {
    description = old.meta.description + " (with system tray support)";
  };
})
