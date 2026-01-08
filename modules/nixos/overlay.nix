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

      # Pending upstream merge of https://github.com/NixOS/nixpkgs/pull/478140
      keyd = super.keyd.overrideAttrs
        (drv: {
          postInstall =
            let
              pypkgs = super.python3.pkgs;

              appMap = pypkgs.buildPythonApplication rec {
                pname = "keyd-application-mapper";
                version = drv.version;
                src = drv.src;
                format = "other";

                postPatch = ''
                  substituteInPlace scripts/${pname} \
                    --replace-fail /bin/sh ${super.runtimeShell}
                '';

                propagatedBuildInputs = with pypkgs; [
                  xlib
                  pygobject3
                  dbus-python
                ];

                dontBuild = true;

                installPhase = ''
                  install -Dm555 -t $out/bin scripts/${pname}
                '';

                meta.mainProgram = "keyd-application-mapper";
              };
            in
            ''
              ln -sf ${super.lib.getExe appMap} $out/bin/${appMap.pname}
              rm -rf $out/etc
            '';
        });

      # GNOME adaptive brightness patches disabled - using wluma instead
      # gnome-settings-daemon = super.gnome-settings-daemon.overrideAttrs (old: {
      #   patches = (old.patches or []) ++ [
      #     ../../patches/gnome-settings-daemon-ambient-brightness-fixes.patch
      #   ];
      # });

      # Fix for suspend loop on GNOME with NVIDIA drivers
      # MR !462: https://gitlab.gnome.org/GNOME/gnome-settings-daemon/-/merge_requests/462
      # Issue #903: https://gitlab.gnome.org/GNOME/gnome-settings-daemon/-/issues/903
      gnome-settings-daemon = super.gnome-settings-daemon.overrideAttrs (old: {
        patches = (old.patches or []) ++ [
          ../../patches/gnome-settings-daemon-suspend-loop-fix.patch
        ];
      });



      # https://github.com/NixOS/nixpkgs/issues/408853
      winbox-quirk = super.winbox4.overrideAttrs (drv: {
        nativeBuildInputs = (drv.nativeBuildInputs or [ ]) ++ [ super.makeWrapper ];
        postFixup = ''
          wrapProgram $out/bin/WinBox --set "QT_QPA_PLATFORM" "xcb"
        '';
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

      # GCC 15 enables -Wunterminated-string-initialization by default which breaks wimboot
      # The BOOTAPP_SIGNATURE arrays intentionally lack null terminators
      # Use EXTRA_CFLAGS (not CFLAGS) to avoid overriding Makefile's internal CFLAGS (which sets VERSION)
      wimboot = super.wimboot.overrideAttrs (old: {
        makeFlags = (old.makeFlags or [ ]) ++ [
          "EXTRA_CFLAGS=-Wno-unterminated-string-initialization"
        ];
      });
    })
  ];
}
