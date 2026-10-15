{ far2l, lib, xdg-utils }:

# NetRocks (via Samba) and the xdg-utils wrapper pull X11 into a TTY build.
(far2l.override {
  withGUI = false;
  withTTYX = false;
  withNetRocks = false;
}).overrideAttrs (old: let
  xdgSuffix = "\\\n  --suffix PATH : ${lib.makeBinPath [ xdg-utils ]}";
  cleanedPostInstall = builtins.replaceStrings [ xdgSuffix ] [ "" ] old.postInstall;
in {
  postInstall = assert builtins.stringLength cleanedPostInstall < builtins.stringLength old.postInstall;
    cleanedPostInstall;
})
