{ lib, stdenv, ghostty, ncurses }:

# Standalone Ghostty terminfo database, compiled with `tic` from the vendored
# terminfo source (./ghostty.terminfo). Upstream's `ghostty.terminfo` and
# `ghostty-bin.terminfo` are split OUTPUTS of the full ghostty derivations:
# Nix builds a derivation as a whole to realize any single output, so
# referencing them here dragged gtk4, libadwaita, blueprint-compiler,
# gstreamer and the zig toolchain into the build closure of every host —
# including headless servers — that only needs a terminfo entry for remote
# ghostty sessions. This derivation depends on ncurses alone.
#
# On a ghostty version bump, regenerate ./ghostty.terminfo from the new
# upstream terminfo output (`infocmp -x`, see the file header); the assert
# below fails the build until that is done.
assert lib.assertMsg (ghostty.version == "1.3.1")
  "pkg/ghostty-terminfo: ghostty is now ${ghostty.version}; regenerate ghostty.terminfo from the new upstream terminfo output";
stdenv.mkDerivation {
  pname = "ghostty-terminfo";
  inherit (ghostty) version;

  dontUnpack = true;

  nativeBuildInputs = [ ncurses ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/terminfo
    tic -x -o $out/share/terminfo ${./ghostty.terminfo}
    runHook postInstall
  '';
}
