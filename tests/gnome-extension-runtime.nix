{ pkgs }:
let
  extensionPkgs = (pkgs.extend (import ../pkg/dim-completed-calendar-events/overlay.nix))
    .extend (import ../pkg/gsconnect/overlay.nix);
  quiet = extensionPkgs.callPackage ../pkg/gnome-shortcut-inhibitor { };
  calendar = extensionPkgs.gnome51Extensions."dim-completed-calendar-events@marcinjahn.com";
  gsconnect = extensionPkgs.gnome51Extensions."gsconnect@andyholmes.github.io";
in
pkgs.runCommand "gnome-extension-runtime" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${./gnome-extension-runtime.py} \
    ${pkgs.gnome-shell} ${pkgs.mutter} ${pkgs.gjs}/bin/gjs \
    ${./gnome-extension-runtime.js} \
    ${quiet}/share/gnome-shell/extensions/${quiet.extensionUuid}/extension.js \
    ${calendar}/share/gnome-shell/extensions/${calendar.extensionUuid}/extension.js \
    ${gsconnect}/share/gnome-shell/extensions/${gsconnect.extensionUuid}/shell/tooltip.js
  touch "$out"
''
