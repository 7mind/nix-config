{
  lib,
  stdenv,
  glib,
  src,
  ...
}:

let
  metadata = builtins.fromJSON (builtins.readFile "${src}/metadata.json");
  uuid = metadata.uuid;
in
stdenv.mkDerivation {
  pname = "gnome-shell-extension-classic-app-switcher";
  version = metadata."version-name";

  inherit src;

  nativeBuildInputs = [ glib ];

  buildPhase = ''
    runHook preBuild
    glib-compile-resources --sourcedir=data/icons --target=data/resources.gresource data/resources.gresource.xml
    glib-compile-schemas --strict schemas
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/gnome-shell/extensions
    cp -r -T . $out/share/gnome-shell/extensions/${uuid}
    runHook postInstall
  '';

  meta = {
    description = "Mouse-friendly application switching for GNOME Shell";
    homepage = "https://github.com/neko-kai/classic-app-switcher";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };

  passthru = {
    extensionPortalSlug = "classic-app-switcher";
    extensionUuid = uuid;
  };
}
