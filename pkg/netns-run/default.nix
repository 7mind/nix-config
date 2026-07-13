{ lib, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  name = "netns-run";
  src = ./.;

  installPhase = ''
    mkdir -p $out/bin
    substitute netns-run.sh $out/bin/netns-run --subst-var out
    cp netns-exec.sh $out/bin/netns-exec
    chmod +x $out/bin/netns-run $out/bin/netns-exec
  '';

  meta = {
    description = "Run commands inside a network namespace via firejail or a netns-exec helper";
    mainProgram = "netns-run";
    platforms = lib.platforms.linux;
  };
}
