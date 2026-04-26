{ lib
, buildNpmPackage
, fetchFromGitHub
, glib
, ...
}:

buildNpmPackage rec {
  pname = "gnome-shell-extension-touchpad-gesture-customization-app-expose";
  version = "0-unstable-2026-04-26";

  uuid = "touchpad-gesture-customization@coooolapps.com";

  src = fetchFromGitHub {
    owner = "7mind";
    repo = "touchpad-gesture-customization-app-expose";
    rev = "3c2d4d1b962587dae0c7a8c85ab96fa4bffe6c2b";
    hash = "sha256-WvfSmg9svMgTeAedXJwKENmDfm5rx0BfStrmfWlfdqU=";
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
