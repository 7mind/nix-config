# Updating this package:
# 1. Find the latest upstream commit:
#    git ls-remote https://github.com/7mind/touchpad-gesture-customization-app-expose.git HEAD
# 2. Update `version` to 0-unstable-YYYY-MM-DD using that commit's date and set `rev`.
# 3. Temporarily set `hash = lib.fakeHash;`, build the package, and copy the reported source hash.
# 4. Temporarily set `npmDepsHash = lib.fakeHash;`, build the package, and copy the reported npm hash.
# 5. Verify with:
#    nix build --impure --option substituters https://cache.nixos.org --expr 'let flake = builtins.getFlake "git+file:///home/kai/src/nix-config?submodules=1"; in flake.pkgs.${builtins.currentSystem}.callPackage ./pkg/touchpad-gesture-customization-app-expose/default.nix { }'
#    ./verify-configs --verbose

{ lib
, buildNpmPackage
, fetchFromGitHub
, glib
, ...
}:

buildNpmPackage rec {
  pname = "gnome-shell-extension-touchpad-gesture-customization-app-expose";
  version = "0-unstable-2026-04-27";

  uuid = "touchpad-gesture-customization@coooolapps.com";

  src = fetchFromGitHub {
    owner = "7mind";
    repo = "touchpad-gesture-customization-app-expose";
    rev = "4c1779ff57c92e450789d823595f6a51fbb34b19";
    hash = "sha256-Q+kQeJqeg6G1XQPyJI/WaL0Hl4v4+tTF93nZlgsjRhs=";
  };

  npmDepsHash = "sha256-vYX1P4A8QePeKqKsg6IyKCC4ujEHt0Kru0k9gWAEOj0=";

  nativeBuildInputs = [ glib ];

  postBuild = ''
    cp -r extension/assets extension/stylesheet.css extension/ui extension/schemas metadata.json build/
    if [ -d build/schemas ]; then
      glib-compile-schemas --strict build/schemas
    fi
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/gnome-shell/extensions
    cp -r -T build $out/share/gnome-shell/extensions/${uuid}
    runHook postInstall
  '';

  meta = {
    description = "Touchpad Gesture Customization GNOME Shell extension (7mind fork with app-expose support)";
    homepage = "https://github.com/7mind/touchpad-gesture-customization-app-expose";
    license = lib.licenses.lgpl3Plus;
    platforms = lib.platforms.linux;
  };

  passthru = {
    extensionPortalSlug = "touchpad-gesture-customization";
    extensionUuid = uuid;
  };
}
