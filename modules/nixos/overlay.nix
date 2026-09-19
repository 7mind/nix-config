{
  pkgs,
  cfg-meta,
  cfg-flakes,
  inputs,
  ...
}:

{
  nixpkgs.overlays = [
    (final: prev: {
      # Standalone ghostty terminfo, avoiding the full GUI app (gtk4, libadwaita,
      # gstreamer, ...). Parses the terminfo from ghostty's Zig source, tic-compiles.
      ghostty-terminfo = prev.callPackage ../../pkg/ghostty-terminfo { };

      fastfetch-minimal = prev.callPackage ../../pkg/fastfetch-minimal { };

      llama-swap = (prev.llama-swap.override {
        buildGoModule = prev.buildGo127Module;
      }).overrideAttrs (old: {
        version = "256";
        src = old.src.override {
          tag = "v256";
          hash = "sha256-midZ5/eq4ULDhCC3wtzman0OdH5bHMIO8FsmzizU8sc=";
        };
        vendorHash = "sha256-R9VOAmoRXet7zoEYo7LW/awJludS4AxRlFDR6skPxbo=";
        excludedPackages = [
          "cmd/misc"
          "cmd/fake-model"
          "cmd/monitor-test"
          "cmd/test-concurrency"
          "cmd/vllm-wrapper"
        ] ++ prev.lib.optionals (!prev.stdenv.buildPlatform.canExecute prev.stdenv.hostPlatform) [
          "cmd/simple-responder"
        ];
        passthru = old.passthru // {
          ui = old.passthru.ui.overrideAttrs (ui:
            let
              sourceRoot = "${ui.src.name}/ui";
              npmDepsHash = "sha256-lmhRJ8275PIQ+7vHdr9aZ31lYeXUkXrWnlvuwOadjRQ=";
            in {
              inherit sourceRoot npmDepsHash;
              npmDeps = ui.npmDeps.overrideAttrs {
                inherit sourceRoot;
                outputHash = npmDepsHash;
              };
            });
        };
      });

      # nixpkgs' 0.3.38 accesses struct nilfs internals removed in nilfs-utils 2.3.
      partclone = prev.partclone.overrideAttrs (old: {
        version = "0.3.50";
        src = prev.fetchFromGitHub {
          owner = "Thomas-Tsai";
          repo = "partclone";
          rev = "0.3.50";
          hash = "sha256-k63VP/F8mGdE17CWMBTuJeJ9W2MdPLcG4bxsWm08VcA=";
        };
        nativeBuildInputs = old.nativeBuildInputs ++ [
          prev.gettext
          prev.libxslt
          prev.docbook_xsl
          prev.docbook_xml_dtd_45
        ];
        buildInputs = old.buildInputs ++ [
          prev.xxhash
          prev.liburcu
          prev.zlib
          prev.zstd
        ];
      });
    })
    (
      _self: super: {
        ip-update = pkgs.callPackage "${cfg-meta.paths.pkg}/ip-update/ip-update.nix" { };

        nordvpn-wireguard-extractor =
          pkgs.callPackage "${cfg-meta.paths.pkg}/nordvpn-wireguard-extractor/default.nix"
            { };

        gnome-shortcut-inhibitor =
          pkgs.callPackage "${cfg-meta.paths.pkg}/gnome-shortcut-inhibitor/default.nix"
            { };

        gnome-shell-extension-classic-app-switcher =
          pkgs.callPackage "${cfg-meta.paths.pkg}/classic-app-switcher/default.nix"
            {
              src = inputs.classic-app-switcher;
            };

        gnome-shell-extension-touchpad-gesture-customization-app-expose =
          inputs.touchpad-gesture-customization-app-expose.packages.${super.system}.default;

        menlo = pkgs.callPackage "${cfg-meta.paths.pkg}/menlo/menlo.nix" { };

        extract-initrd = pkgs.callPackage "${cfg-meta.paths.pkg}/extract-initrd/default.nix" { };

        netns-run = pkgs.callPackage "${cfg-meta.paths.pkg}/netns-run/default.nix" { };

        music-meta-fix = pkgs.callPackage "${cfg-meta.paths.pkg}/music-meta-fix/default.nix" { };

        saic-mqtt-gateway = pkgs.callPackage "${cfg-meta.paths.pkg}/saic-mqtt-gateway/default.nix" { };

        hoymiles-mqtt-bridge =
          pkgs.callPackage "${cfg-meta.paths.pkg}/hoymiles-mqtt-bridge/default.nix"
            { };

        enocean-mqtt = pkgs.callPackage "${cfg-meta.paths.pkg}/enocean-mqtt/default.nix" { };

        matter-mqtt-bridge = pkgs.callPackage "${cfg-meta.paths.pkg}/matter-mqtt-bridge/default.nix" { };

        resock = pkgs.callPackage "${cfg-meta.paths.pkg}/resock/default.nix" { };
        # nixpkgs liblinphone 5.4.85 includes ZXing/TextUtfEncoding.h, removed
        # in zxing-cpp 3.x. encode() now takes UTF-8 std::string directly.
        linphonePackages = super.linphonePackages.overrideScope (
          _lfinal: lprev: {
            liblinphone = lprev.liblinphone.overrideAttrs (old: {
              postPatch = (old.postPatch or "") + ''
                substituteInPlace src/factory/factory.cpp \
                  --replace-fail '#include <ZXing/TextUtfEncoding.h>' '/* zxing-cpp 3.x dropped TextUtfEncoding.h */' \
                  --replace-fail '#include <TextUtfEncoding.h>' '/* zxing-cpp 3.x dropped TextUtfEncoding.h */' \
                  --replace-fail 'ZXing::TextUtfEncoding::FromUtf8(code)' 'code'
              '';
            });
          }
        );

        flexisip = pkgs.callPackage "${cfg-meta.paths.pkg}/flexisip/default.nix" { };
        flexisip-conference = pkgs.callPackage "${cfg-meta.paths.pkg}/flexisip-conference/default.nix" { };
        flexisip-http-file-transfer-server =
          pkgs.callPackage "${cfg-meta.paths.pkg}/flexisip-http-file-transfer-server/default.nix"
            { };

        zigbee-mqtt-import = pkgs.callPackage "${cfg-meta.paths.pkg}/zigbee-mqtt-import/default.nix" { };
        linux-3-finger-drag = pkgs.callPackage "${cfg-meta.paths.pkg}/linux-3-finger-drag/default.nix" { };

        # Workaround for NAS-WR01ZE bit-31 firmware bug (zwave-js/zwave-js#2692):
        # device randomly sets bit 31 in the 4-byte meter report mantissa, giving
        # values near -21,474,836 instead of small positives; mask the MSB when the
        # parsed value is implausibly negative. Applied on top of nixpkgs'
        # zwave-js-ui (11.22.2 / zwave-js 15.27.0); the compiled MeterCC strings
        # were re-checked against that release.
        zwave-js-ui =
          let
            bit31Fix = "if (value < -1e6) { const _p = data.subarray(offset + 1); const _prec = (_p[0] & 224) >>> 5; const _sz = _p[0] & 7; if (_sz === 4) value = (((_p[1] & 0x7F) << 24) | (_p[2] << 16) | (_p[3] << 8) | _p[4]) / Math.pow(10, _prec); }";
            meterCCPath = "lib/node_modules/zwave-js-ui/node_modules/@zwave-js/cc/build";
          in
          super.zwave-js-ui.overrideAttrs (old: {
            postInstall = (old.postInstall or "") + ''
              substituteInPlace "$out/${meterCCPath}/cjs/cc/MeterCC.js" \
                --replace-fail \
                "const { scale: scale1Bits10, value, bytesRead } = (0, import_core.parseFloatWithScale)(data.subarray(offset + 1));" \
                "let { scale: scale1Bits10, value, bytesRead } = (0, import_core.parseFloatWithScale)(data.subarray(offset + 1)); ${bit31Fix}"
              substituteInPlace "$out/${meterCCPath}/esm/cc/MeterCC.js" \
                --replace-fail \
                "const { scale: scale1Bits10, value, bytesRead, } = parseFloatWithScale(data.subarray(offset + 1));" \
                "let { scale: scale1Bits10, value, bytesRead, } = parseFloatWithScale(data.subarray(offset + 1)); ${bit31Fix}"
            '';
          });

        # nixpkgs still ships 22.8.2. Use the complete upstream security release
        # rather than carrying one advisory's patch while leaving the other fixes
        # from 22.9.0 onward absent.
        asterisk = super.asterisk.overrideAttrs (old: rec {
          version = "22.11.0";
          src = super.fetchurl {
            url = "https://downloads.asterisk.org/pub/telephony/asterisk/old-releases/asterisk-${version}.tar.gz";
            hash = "sha256-O9XuBAUJo9PNmxupUgwY5uwKfnmBymjEV9zTa6PFTZQ=";
          };
          preConfigure = (old.preConfigure or "") + ''
            chmod +w externals_cache
            cp --no-preserve=mode ${
              super.fetchurl {
                url = "https://raw.githubusercontent.com/asterisk/third-party/master/pjproject/2.17/pjproject-2.17.tar.bz2";
                hash = "sha256-BLLrHw8BqgrRlFsWcXGENEilGqa3w+gGSW1DTxOhErc=";
              }
            } externals_cache/pjproject-2.17.tar.bz2
            chmod -w externals_cache
          '';
        });

        fractal = cfg-flakes.fractal.fractal-tray;

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

        # NOTE: the GTK-file-chooser GSettings schema crash (Shotcut, AmneziaVPN,
        # ...) is fixed globally via GSETTINGS_SCHEMA_DIR in
        # modules/nixos/env-settings-linux-desktop.nix, not per-package here.

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

        nix-apple-fonts = (
          cfg-flakes.nix-apple-fonts.default.overrideAttrs (drv: {
            # Install fonts into /share/fonts, not /usr/share/fonts where they
            # don't work. FIXME: notify upstream / submit PR?
            installPhase = ''
              runHook preInstall
              mkdir -p $out/share/fonts/opentype
              for folder in $src/fonts/*; do
                  install -Dm644 "$folder"/*.otf -t $out/share/fonts/opentype
              done
              mkfontdir "$out/share/fonts/opentype"
              runHook postInstall
            '';
          })
        );

        smfc = super.python3Packages.buildPythonApplication rec {
          pname = "smfc";
          version = "6.4.2";
          pyproject = true;

          src = super.fetchFromGitHub {
            owner = "petersulyok";
            repo = "smfc";
            tag = "v${version}";
            hash = "sha256-2YRQnHiG+4vWKJ3CZ+jyra5A6i+wAz2x+1ET1gas41o=";
          };

          build-system = [ super.python3Packages.setuptools ];
          dependencies = [ super.python3Packages.pyudev ];

          nativeBuildInputs = [ super.makeWrapper ];
          postFixup = ''
            wrapProgram $out/bin/smfc \
              --prefix LD_LIBRARY_PATH : ${super.lib.makeLibraryPath [ super.systemd ]}
          '';

          doCheck = false;

          meta = {
            description = "Supermicro Fan Control for Linux";
            homepage = "https://github.com/petersulyok/smfc";
            license = super.lib.licenses.gpl3Only;
            platforms = [ "x86_64-linux" ];
          };
        };

      }
    )
  ];
}
