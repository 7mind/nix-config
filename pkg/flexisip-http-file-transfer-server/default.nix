{
  lib,
  stdenvNoCC,
  fetchFromGitLab,
}:

stdenvNoCC.mkDerivation {
  pname = "flexisip-http-file-transfer-server";
  version = "1.1.1-beta";

  src = fetchFromGitLab {
    domain = "gitlab.linphone.org";
    owner = "BC/public";
    repo = "flexisip-http-file-transfer-server";
    rev = "5b5aa5fc0782262d8c50d000aa3d0da58300ab08";
    hash = "sha256-OXMWnuka/7AgXt1ZqDxZ/X7+L9ZIEeX/ilWRRD+bqTU=";
  };

  installPhase = ''
    runHook preInstall

    install -Dm0444 src/common.php src/download.php src/hft.php \
      -t "$out/share/flexisip-http-file-transfer-server"

    runHook postInstall
  '';

  meta = {
    description = "Linphone-compatible RCS HTTP file transfer server";
    homepage = "https://gitlab.linphone.org/BC/public/flexisip-http-file-transfer-server";
    license = lib.licenses.agpl3Plus;
    platforms = lib.platforms.all;
  };
}
