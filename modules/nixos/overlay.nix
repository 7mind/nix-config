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
      # patch can be found in git history

      # Fix suspend loop with GNOME+NVIDIA
      # https://github.com/NixOS/nixpkgs/issues/336723#issuecomment-3724194485
      # https://gitlab.gnome.org/GNOME/gnome-settings-daemon/-/merge_requests/462
      # https://gitlab.gnome.org/GNOME/gnome-settings-daemon/-/commit/44e1cc564b02349adab38e691770f13c0e09951b
      # https://github.com/GNOME/gnome-settings-daemon/commit/44e1cc564b02349adab38e691770f13c0e09951b
      gnome-settings-daemon = super.gnome-settings-daemon.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (pkgs.fetchpatch {
            url = "https://gitlab.gnome.org/GNOME/gnome-settings-daemon/-/commit/44e1cc564b02349adab38e691770f13c0e09951b.patch";
            name = "fix-gnome-sleep-loop.patch";
            hash = "sha256-hElYD91/1/LO9SaUYNZaIlzIKmOSVPVpGy9v4PwsTi4=";
          })
        ];
      });

      # Fix for black screen on resume (remove lock screen animation during suspend)
      # MR !3742: https://gitlab.gnome.org/GNOME/gnome-shell/-/merge_requests/3742
      gnome-shell = super.gnome-shell.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (pkgs.fetchpatch {
            url = "https://gitlab.gnome.org/GNOME/gnome-shell/-/merge_requests/3742.patch";
            name = "gnome-shell-remove-lock-animation-on-suspend.patch";
            hash = "sha256-ZJ+Mq7VbYYZLC4/3iM9L7ZAiZX2FcrRZCOI2s7cSQCw=";
          })
        ];
      });

            # Fix for cursor stutter/lag

            # Issue: https://gitlab.gnome.org/GNOME/mutter/-/issues/4518

            # MR !4795: https://gitlab.gnome.org/GNOME/mutter/-/merge_requests/4795

            # MR !4833: https://gitlab.gnome.org/GNOME/mutter/-/merge_requests/4833

            #

            # Includes 49.3 backports:

            # - screencast: Fix cursor stutter/lag by accumulating damage correctly (Closes #4380)

            # - screencast: Fix damage region coordinates for PipeWire consumers (Closes #4269)

            # - screencast: Handle blit failures and fallback to drawing

            # - wayland: Fix subsurface geometry calculation (Closes #4250)

            # - x11: Fix sync counter issues by reverting per-view frame counter (Closes #4216)

            # - xwayland: Fix inconsistent layout due to monitor scale updates

            # - misc: Fix memory leaks in text-accessible and CICP initialization issues (Closes #4534, #4344)

            #

            # DISABLED: MR !4795 (input-settings: Hook up disable-while-typing timeout)

            # Fails to compile with libinput 1.29.0 (missing libinput_device_config_dwt_set_timeout)

            mutter = super.mutter.overrideAttrs (old: {

              patches = (old.patches or [ ]) ++ [

                (pkgs.fetchpatch {

                  url = "https://gitlab.gnome.org/GNOME/mutter/-/merge_requests/4833.patch";

                  name = "mutter-fix-cursor-stutter.patch";

                  hash = "sha256-Rtew+2BsQN4XU8x4Ge0Sjr1BoFFSWYrahVHYN+fq5jk=";

                })

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
