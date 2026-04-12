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
      # Standalone ghostty terminfo derivation that avoids building the full
      # ghostty GUI app (which pulls in gtk4, libadwaita, gstreamer, etc.).
      # Parses the terminfo definition from ghostty's Zig source and compiles
      # it with tic.
      ghostty-terminfo =
        prev.runCommand "ghostty-terminfo-${prev.ghostty.version}"
          {
            nativeBuildInputs = [ prev.ncurses ];
          }
          ''
            ${prev.python3.interpreter} ${prev.writeText "gen-ghostty-ti.py" ''
              import re, sys
              with open(sys.argv[1]) as f:
                  content = f.read()
              names_match = re.search(r'\.names\s*=\s*&\.\{(.*?)\}', content, re.DOTALL)
              names = re.findall(r'"([^"]+)"', names_match.group(1))
              caps = []
              for line in content.split('\n'):
                  m = re.search(r'\.name\s*=\s*"([^"]+)"', line)
                  if not m:
                      continue
                  name = m.group(1)
                  if '.boolean' in line:
                      caps.append(f"\t{name},")
                  elif '.canceled' in line:
                      caps.append(f"\t{name}@,")
                  elif '.numeric' in line:
                      nm = re.search(r'\.numeric\s*=\s*(\d+)', line)
                      caps.append(f"\t{name}#{nm.group(1)},")
                  elif '.string' in line:
                      sm = re.search(r'\.string\s*=\s*"([^"]*)"', line)
                      s = sm.group(1).replace('\\\\', '\\')
                      caps.append(f"\t{name}={s},")
              print('|'.join(names) + ',')
              print('\n'.join(caps))
            ''} ${prev.ghostty.src}/src/terminfo/ghostty.zig > ghostty.ti
            mkdir -p $out/share/terminfo
            tic -x -o $out/share/terminfo ghostty.ti
          '';
    })
    (
      self: super:
      let
        ollamaVersion = "0.20.0";
        mkPinnedOllama =
          pkg:
          pkg.overrideAttrs (_: {
            version = ollamaVersion;
            src = super.fetchFromGitHub {
              owner = "ollama";
              repo = "ollama";
              tag = "v${ollamaVersion}";
              hash = "sha256-QQKPXdXlsT+uMGGIyqkVZqk6OTa7VHrwDVmgDdgdKOY=";
            };
            vendorHash = "sha256-Lc1Ktdqtv2VhJQssk8K1UOimeEjVNvDWePE9WkamCos=";
          });

        mqtt-controller-src = pkgs.lib.cleanSourceWith {
          src = "${cfg-meta.paths.pkg}/mqtt-controller";
          filter = name: type:
            let baseName = baseNameOf (toString name); in
            ! (type == "directory" && baseName == "target");
        };
      in
      {
        ollama = mkPinnedOllama super.ollama;
        ollama-cpu = mkPinnedOllama super.ollama-cpu;
        ollama-vulkan = mkPinnedOllama super.ollama-vulkan;
        ollama-rocm = mkPinnedOllama super.ollama-rocm;
        ollama-cuda = mkPinnedOllama super.ollama-cuda;

        ip-update = pkgs.callPackage "${cfg-meta.paths.pkg}/ip-update/ip-update.nix" { };

        nordvpn-wireguard-extractor =
          pkgs.callPackage "${cfg-meta.paths.pkg}/nordvpn-wireguard-extractor/default.nix"
            { };

        gnome-shortcut-inhibitor =
          pkgs.callPackage "${cfg-meta.paths.pkg}/gnome-shortcut-inhibitor/default.nix"
            { };

        menlo = pkgs.callPackage "${cfg-meta.paths.pkg}/menlo/menlo.nix" { };

        extract-initrd = pkgs.callPackage "${cfg-meta.paths.pkg}/extract-initrd/default.nix" { };

        llm-sandbox = pkgs.callPackage "${cfg-meta.paths.pkg}/llm-sandbox/default.nix" { };

        netns-run = pkgs.callPackage "${cfg-meta.paths.pkg}/netns-run/default.nix" { };

        reattach-llm = pkgs.callPackage "${cfg-meta.paths.pkg}/reattach-llm/default.nix" { };

        music-meta-fix = pkgs.callPackage "${cfg-meta.paths.pkg}/music-meta-fix/default.nix" { };

        mqtt-controller-frontend =
          let
            craneLib = (inputs.crane.mkLib pkgs).overrideToolchain (p:
              p.rust-bin.stable.latest.default.override {
                targets = [ "wasm32-unknown-unknown" ];
              }
            );
            commonArgs = {
              src = mqtt-controller-src;
              cargoToml = "${mqtt-controller-src}/crates/mqtt-controller-frontend/Cargo.toml";
              cargoExtraArgs = "-p mqtt-controller-frontend";
            };
            cargoArtifacts = craneLib.buildDepsOnly (commonArgs // {
              CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
              doCheck = false;
            });
          in
          craneLib.buildTrunkPackage (commonArgs // {
            inherit cargoArtifacts;
            wasm-bindgen-cli = pkgs.wasm-bindgen-cli;
            # trunk must run from the frontend crate directory so it can
            # find the [package] Cargo.toml. We cd there before trunk
            # runs and adjust the install path accordingly.
            preBuild = "cd crates/mqtt-controller-frontend";
            trunkIndexPath = "./index.html";
            installPhaseCommand = "cp -r dist $out";
          });

        mqtt-controller =
          let
            craneLib = (inputs.crane.mkLib pkgs).overrideToolchain (p:
              p.rust-bin.stable.latest.default
            );
            commonArgs = {
              src = mqtt-controller-src;
              cargoExtraArgs = "-p mqtt-controller";
              nativeBuildInputs = [ pkgs.mold ];
            };
            cargoArtifacts = craneLib.buildDepsOnly (commonArgs // {
              doCheck = false;
            });
          in
          craneLib.buildPackage (commonArgs // {
            inherit cargoArtifacts;
            cargoTestExtraArgs = "-p mqtt-controller -p mqtt-controller-wire";
            doCheck = true;
            postInstall = pkgs.lib.optionalString (self.mqtt-controller-frontend != null) ''
              mkdir -p $out/share/mqtt-controller
              cp -r ${self.mqtt-controller-frontend} $out/share/mqtt-controller/web
              chmod -R u+w $out/share/mqtt-controller/web
            '';
            passthru = {
              inherit (self) mqtt-controller-frontend;
            };
            meta = with pkgs.lib; {
              description = "Unified zigbee2mqtt provisioner and runtime controller";
              license = licenses.mit;
              maintainers = with maintainers; [ pshirshov ];
              mainProgram = "mqtt-controller";
              platforms = platforms.linux;
            };
          });

        zigbee-mqtt-import = pkgs.callPackage "${cfg-meta.paths.pkg}/zigbee-mqtt-import/default.nix" { };
        linux-3-finger-drag = pkgs.callPackage "${cfg-meta.paths.pkg}/linux-3-finger-drag/default.nix" { };

        # Workaround for NAS-WR01ZE bit-31 firmware bug (zwave-js/zwave-js#2692).
        # The device randomly sets bit 31 in 4-byte meter report mantissa,
        # causing values near -21,474,836 instead of small positive numbers.
        # We mask off the MSB when the parsed meter value is implausibly negative.
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

      fractal = cfg-flakes.fractal.fractal-tray.overrideAttrs (old: {
              cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
                inherit (old) src;
                hash = "sha256-uULj/9ixqq9cGg7U1m4QnfTl6Hvpjx0nJPjWvF2rW2M=";
              };
            });

        # Pending upstream merge of https://github.com/NixOS/nixpkgs/pull/478140
        keyd = super.keyd.overrideAttrs (drv: {
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

        nix-apple-fonts = (
          cfg-flakes.nix-apple-fonts.default.overrideAttrs (drv: {
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
          })
        );

        # GCC 15 enables -Wunterminated-string-initialization by default which breaks wimboot
        # The BOOTAPP_SIGNATURE arrays intentionally lack null terminators
        # Use EXTRA_CFLAGS (not CFLAGS) to avoid overriding Makefile's internal CFLAGS (which sets VERSION)
        wimboot = super.wimboot.overrideAttrs (old: {
          makeFlags = (old.makeFlags or [ ]) ++ [
            "EXTRA_CFLAGS=-Wno-unterminated-string-initialization"
          ];
        });

      }
    )
  ];
}
