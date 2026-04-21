{ lib, stdenvNoCC, bash, coreutils, openssh, makeWrapper }:

stdenvNoCC.mkDerivation {
  pname = "resock";
  version = "0.1.0";

  src = ./resock.sh;
  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/resock
    # Guarantee `timeout` (coreutils) and `ssh-add` (openssh) are on PATH
    # regardless of how the caller's environment is set up.
    wrapProgram $out/bin/resock \
      --prefix PATH : ${lib.makeBinPath [ coreutils openssh ]}
    runHook postInstall
  '';

  meta = {
    description = "Probe + reselect SSH_AUTH_SOCK, print an evalable export";
    license = lib.licenses.mit;
    mainProgram = "resock";
    platforms = lib.platforms.unix;
  };
}
