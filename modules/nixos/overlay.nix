{ pkgs, cfg-meta, cfg-flakes, ... }:

{
  nixpkgs.overlays = [
    (self: super: {
      ip-update = pkgs.callPackage "${cfg-meta.paths.pkg}/ip-update/ip-update.nix" { };
      qendercore-pull = pkgs.callPackage "${cfg-meta.paths.pkg}/qendercore-pull/qendercore-pull.nix" { };
      stalix-cache = pkgs.callPackage "${cfg-meta.paths.pkg}/stalix-cache/stalix-cache.nix" { };

      gnome-shortcut-inhibitor = pkgs.callPackage "${cfg-meta.paths.pkg}/gnome-shortcut-inhibitor/default.nix" { };

      menlo = pkgs.callPackage "${cfg-meta.paths.pkg}/menlo/menlo.nix" { };

      nix-apple-fonts = (cfg-flakes.nix-apple-fonts.default.overrideAttrs (drv: {
        # override install script to put fonts into /share/fonts, not /usr/share/fonts - where they don't work.
        # FIXME: notify upstream / submit PR?
        installPhase = ''
          runHook preInstall
          mkdir -p $out/share/fonts/opentype
          for folder in $src/fonts/*; do
              install -Dm644 "$folder"/*.otf -t $out/share/fonts/opentype
          done
          mkfontdir "$out/share/fonts/opentype"
          runHook postInstall
        '';
      }));

    })
  ];
}
