{ pkgs, lib, stdenv, ... }:

stdenv.mkDerivation rec {
  basename = "shortcut-inhibitor";
  uuid = "quiet-shortcuts@lernstick.ch";
  pname = "gnome-shell-extension-${basename}";
  version = "1.0.0";

  src = ./gnome-shell-extension-quiet-shortcuts;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/gnome-shell/extensions/
    cp -r -T ./quiet-shortcuts@lernstick.ch $out/share/gnome-shell/extensions/${uuid}
    runHook postInstall
  '';

  meta = {
    description = "";
    longDescription = "";
    homepage = "https://github.com/Lernstick/gnome-shell-extension-quiet-shortcuts";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    maintainers = [ lib.maintainers.honnip ];
  };
  passthru = {
    extensionPortalSlug = pname;
    # Store the extension's UUID, because we might need it at some places
    extensionUuid = uuid;
  };
}
