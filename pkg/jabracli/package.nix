{ lib, fetchurl, appimageTools, buildFHSEnv, _7zz }:

let
  pname = "jabracli";
  version = "1.6.48.0";
  src = fetchurl {
    url = "https://file.cloud.jabra.com/cli-tool/JabraCLI_${version}.AppImage";
    hash = "sha256-tKgUzYDVJXgpLwm8IO8xqEr2OxKDIzRJrRzAYwFYszA=";
  };
  appimageContents = appimageTools.extract { inherit pname version src; };
in
buildFHSEnv {
  inherit pname version;
  runScript = "${appimageContents}/usr/bin/jabracli";
  targetPkgs = pkgs: with pkgs; [
    icu
    openssl
    zlib
    stdenv.cc.cc.lib
    libusb1
    udev
  ];
  # FWU expects this absolute path, not a 7-Zip executable from PATH.
  extraBuildCommands = ''
    mkdir -p $out/usr/lib64/7zip
    ln -s ${_7zz}/bin/7zz $out/usr/lib64/7zip/7za
  '';
  passthru = { inherit src appimageContents; };
  meta = {
    description = "Command-line management of Jabra devices and firmware";
    homepage = "https://developer.jabra.com/sdks-and-tools/jabracli/";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "jabracli";
  };
}
