{ pkgs, cfg-meta, cfg-flakes, ... }:

{
  nixpkgs.overlays = [
    (self: super:
      let
        ollamaVersion = "0.17.6";
        mkPinnedOllama = pkg: pkg.overrideAttrs (_: {
          version = ollamaVersion;
          src = super.fetchFromGitHub {
            owner = "ollama";
            repo = "ollama";
            tag = "v${ollamaVersion}";
            hash = "sha256-Hd2U6FoYwtDPOt+AZhsYloWSF2/QE+fsXRcC6OKKJXA=";
          };
          vendorHash = "sha256-Lc1Ktdqtv2VhJQssk8K1UOimeEjVNvDWePE9WkamCos=";
        });
      in
      {
      ollama = mkPinnedOllama super.ollama;
      ollama-cpu = mkPinnedOllama super.ollama-cpu;
      ollama-vulkan = mkPinnedOllama super.ollama-vulkan;
      ollama-rocm = mkPinnedOllama super.ollama-rocm;
      ollama-cuda = mkPinnedOllama super.ollama-cuda;

      ip-update = pkgs.callPackage "${cfg-meta.paths.pkg}/ip-update/ip-update.nix" { };

      nordvpn-wireguard-extractor = pkgs.callPackage "${cfg-meta.paths.pkg}/nordvpn-wireguard-extractor/default.nix" { };

      gnome-shortcut-inhibitor = pkgs.callPackage "${cfg-meta.paths.pkg}/gnome-shortcut-inhibitor/default.nix" { };

      menlo = pkgs.callPackage "${cfg-meta.paths.pkg}/menlo/menlo.nix" { };

      extract-initrd = pkgs.callPackage "${cfg-meta.paths.pkg}/extract-initrd/default.nix" { };

      firejail-wrap = pkgs.callPackage "${cfg-meta.paths.pkg}/firejail-wrap/default.nix" { };

      netns-run = pkgs.callPackage "${cfg-meta.paths.pkg}/netns-run/default.nix" { };

      reattach-llm = pkgs.callPackage "${cfg-meta.paths.pkg}/reattach-llm/default.nix" { };

      music-meta-fix = pkgs.callPackage "${cfg-meta.paths.pkg}/music-meta-fix/default.nix" { };

      fractal = cfg-flakes.fractal.fractal-tray.overrideAttrs (old: {
        cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
          inherit (old) src;
          hash = "sha256-uULj/9ixqq9cGg7U1m4QnfTl6Hvpjx0nJPjWvF2rW2M=";
        };
      });

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

      # Ensure GNOME Settings can load org.gnome.login-screen schema from gdm.
      # Without this, fingerprint settings row is hidden even when fprintd works.
      gnome-control-center = super.gnome-control-center.overrideAttrs (old: {
        preFixup =
          let
            gdmSchemas = "${super.gdm}/share/gsettings-schemas/${super.gdm.name}";
          in
          (old.preFixup or "")
          + ''
            gappsWrapperArgs+=(--prefix XDG_DATA_DIRS : "${gdmSchemas}")
          '';
      });

      # https://github.com/NixOS/nixpkgs/issues/408853
      winbox-quirk = super.winbox4.overrideAttrs (drv: {
        nativeBuildInputs = (drv.nativeBuildInputs or [ ]) ++ [ super.makeWrapper ];
        postFixup = ''
          wrapProgram $out/bin/WinBox --set "QT_QPA_PLATFORM" "xcb"
        '';
      });

      # Shotcut uses GTK file chooser via Qt portal integration and crashes
      # when GTK schemas are not discoverable in XDG_DATA_DIRS.
      shotcut = super.shotcut.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ super.makeWrapper ];
        postFixup =
          let
            gtk3Schemas = "${super.gtk3}/share/gsettings-schemas/${super.gtk3.name}";
          in
          (old.postFixup or "")
          + ''
            wrapProgram $out/bin/shotcut \
              --prefix XDG_DATA_DIRS : "${gtk3Schemas}"
          '';
      });

      arduino-ide = super.arduino-ide.overrideAttrs (old: {
        buildCommand = (old.buildCommand or "") + ''
          arduino_ide_target="$(readlink "$out/bin/arduino-ide")"
          rm "$out/bin/arduino-ide"
          cat > "$out/bin/arduino-ide" <<EOF
#!${super.runtimeShell}
export LD_LIBRARY_PATH="${super.libxkbfile}/lib:''${LD_LIBRARY_PATH:+:''${LD_LIBRARY_PATH}}"
exec "''${arduino_ide_target}" --no-sandbox --ozone-platform=x11 --disable-gpu --disable-gpu-sandbox "\$@"
EOF
          chmod 0755 "$out/bin/arduino-ide"
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
