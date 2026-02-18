{ lib, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  name = "netns-run";
  src = ./netns-run.sh;

  dontUnpack = true;

  installPhase = ''
    mkdir -p $out/bin
    cp $src $out/bin/netns-run
    chmod +x $out/bin/netns-run
  '';

  meta = {
    description = "Run commands inside a network namespace via firejail";
    mainProgram = "netns-run";
    platforms = lib.platforms.linux;
  };
}
