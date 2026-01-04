{ pkgs, cfg-meta, cfg-flakes, ... }:

{
  nixpkgs.overlays = [
    (self: super: {
      ip-update = pkgs.callPackage "${cfg-meta.paths.pkg}/ip-update/ip-update.nix" { };
      
      qendercore-pull = pkgs.callPackage "${cfg-meta.paths.pkg}/qendercore-pull/qendercore-pull.nix" { };

      nordvpn-wireguard-extractor = pkgs.callPackage "${cfg-meta.paths.pkg}/nordvpn-wireguard-extractor/default.nix" { };

      gnome-shortcut-inhibitor = pkgs.callPackage "${cfg-meta.paths.pkg}/gnome-shortcut-inhibitor/default.nix" { };

      menlo = pkgs.callPackage "${cfg-meta.paths.pkg}/menlo/menlo.nix" { };

      extract-initrd = pkgs.callPackage "${cfg-meta.paths.pkg}/extract-initrd/default.nix" { };

      firejail-wrap = pkgs.callPackage "${cfg-meta.paths.pkg}/firejail-wrap/default.nix" { };

      music-meta-fix = pkgs.callPackage "${cfg-meta.paths.pkg}/music-meta-fix/default.nix" { };

      fractal-tray = pkgs.callPackage "${cfg-meta.paths.pkg}/fractal-tray/default.nix" { };

      # Fix ambient brightness initialization in GNOME 49+ (MR !447)
      # Unbreaks basic auto brightness by fixing normalization and int/float division.
      gnome-settings-daemon = super.gnome-settings-daemon.overrideAttrs (old: {
        patches = (old.patches or []) ++ [
          "${cfg-meta.paths.root}/patches/gnome-settings-daemon-ambient-brightness-fixes.patch"
        ];
      });



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
