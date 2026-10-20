{
  lib,
  stdenvNoCC,
  jq,
  src,
  shellVersion,
}:

let
  extensionSource = src + "/contrib/gnome-shell-extension/hyprwhspr-waveform@ninyawee.github.io";
  metadata = builtins.fromJSON (builtins.readFile (extensionSource + "/metadata.json"));
in
stdenvNoCC.mkDerivation {
  pname = "gnome-shell-extension-hyprwhspr-waveform";
  version = toString metadata.version;
  src = extensionSource;
  nativeBuildInputs = [ jq ];
  dontBuild = true;
  postPatch = ''
    jq --arg version ${lib.escapeShellArg shellVersion} \
      '.["shell-version"] |= (. + [$version] | unique)' metadata.json > metadata.json.tmp
    mv metadata.json.tmp metadata.json
  ''
  + lib.optionalString (lib.versionAtLeast shellVersion "50") ''
    substituteInPlace extension.js \
      --replace-fail '            affectsInputRegion: false,' ""
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/gnome-shell/extensions/${metadata.uuid}"
    cp -r . "$out/share/gnome-shell/extensions/${metadata.uuid}/"
    runHook postInstall
  '';
  passthru.extensionUuid = metadata.uuid;
  meta = {
    description = "GNOME Shell waveform overlay for hyprwhspr dictation";
    homepage = "https://github.com/goodroot/hyprwhspr";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
