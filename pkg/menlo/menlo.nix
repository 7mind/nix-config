{ lib, stdenvNoCC, mkfontdir, mkfontscale, ... }:

stdenvNoCC.mkDerivation rec {
  pname = "menlo";
  version = "17.0d1e1";

  src = ./Menlo.ttc;

  nativeBuildInputs = [
    mkfontscale
    mkfontdir
  ];

  unpackPhase = ''
    cp ${src} ./Menlo.ttc
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 *.ttc -t $out/share/fonts/truetype

    runHook postInstall
  '';

  meta = with lib; {
    description = "Apple Menlo";
    homepage = "https://apple.com/";
    license = licenses.unfree;
    maintainers = with maintainers; [ ];
    platforms = platforms.all;
  };
}
