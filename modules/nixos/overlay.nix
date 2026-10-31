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
      hyprwhspr = prev.callPackage ../../pkg/hyprwhspr { src = inputs.hyprwhspr; };

      # Standalone ghostty terminfo, avoiding the full GUI app (gtk4, libadwaita,
      # gstreamer, ...), using upstream's dedicated output.
      ghostty-terminfo = prev.callPackage ../../pkg/ghostty-terminfo { };

      llama-swap = prev.llama-swap.overrideAttrs (old: {
        version = "268";
        src = old.src.override {
          tag = "v268";
          hash = "sha256-nwH4AMiC5b4elrG9m/HExOYM8P3r1YaWghPXUpoW/xU=";
        };
        vendorHash = "sha256-nauMUxfDugvYnA74eVm8jaUt+l1V7gNvL89f6l2Ls8w=";
      });

      # intel-llvm's Sphinx docs targets run with warnings-as-errors and
      # Sphinx >= 8.2 trips over the SYCL attribute examples (pygments
      # misc.highlighting_failure warnings become fatal) — upstream:
      # intel/llvm#23649. The toolchain is consumed for its compiler and
      # libraries, so drop docs/manpages via the package's own switch
      # (upstream-verified alternative that keeps docs:
      # -DSPHINX_WARNINGS_AS_ERRORS=OFF).
      intel-llvm = prev.intel-llvm.overrideScope (llvm-final: llvm-prev: {
        unwrapped = llvm-prev.unwrapped.override { enableManpages = false; };
      });

      # unified-memory-framework 1.2.0's IPC ctest scripts (test/ipc_*.sh)
      # carry their shebang below the leading copyright comment, so execve()
      # treats them as shebang-less and ctest (executing them directly) fails
      # them with ENOEXEC ("exec format error"). Fixed upstream by
      # oneapi-src/unified-memory-framework#1618 (merged 2026-10-26); v1.2.0
      # predates it. Disable exactly those tests until the pin moves past
      # 1.2.0, then drop this override.
      unified-memory-framework = prev.unified-memory-framework.overrideAttrs (old: {
        disabledTests = (old.disabledTests or [ ]) ++ [
          "test_ipc_os_prov_anon_fd"
          "test_ipc_os_prov_shm"
          "test_ipc_devdax_prov"
          "test_ipc_file_prov"
          "test_ipc_file_prov_fsdax"
        ];
      });

      # vmnet-natd is the package's only ET_EXEC (non-PIE) daemon binary.
      # patchelf's rpath relocation (autoPatchelfHook) moves its .dynamic
      # into a read-only LOAD segment, so glibc's loader segfaults in
      # dl_main before main() and vmware-networks can never start NAT on
      # vmnet8 (upstream: NixOS/patchelf#146, NixOS/patchelf#152). Run
      # autoPatchelf manually on everything except vmnet-natd, then patch
      # natd's interpreter only and supply its libraries via a wrapper.
      vmware-workstation = prev.vmware-workstation.overrideAttrs (old: {
        dontAutoPatchelf = true;
        postFixup = ''
          mapfile -t vmwareBinFiles < <(find "$out/bin" -type f ! -name vmnet-natd -print)
          autoPatchelf -- "$out/lib" "''${vmwareBinFiles[@]}"

          patchelf --set-interpreter "$(cat "$NIX_CC/nix-support/dynamic-linker")" "$out/bin/vmnet-natd"
          wrapProgram "$out/bin/vmnet-natd" \
            --prefix LD_LIBRARY_PATH : "${prev.lib.makeLibraryPath [ prev.openssl prev.stdenv.cc.libc ]}"
        '';
      });

      partclone = prev.partclone.overrideAttrs (old: {
        version = "0.3.52";
        src = old.src.override {
          rev = "0.3.52";
          hash = "sha256-tffPKO28Qh/6hY46HuRQP4XsSqq2sideEQGQC/SwMC8=";
        };
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

        # Use the complete upstream 23.5 release, including its security fixes.
        # The paired pjproject archive matches third-party/versions.mak.
        asterisk = super.asterisk.overrideAttrs (old: rec {
          version = "23.5.0";
          src = super.fetchurl {
            url = "https://downloads.asterisk.org/pub/telephony/asterisk/old-releases/asterisk-${version}.tar.gz";
            hash = "sha256-jtOiN+bY3/lKCVJ6gxQ1MLWvzBruc/p7hcBpvaUHraw=";
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

        nix-apple-fonts = cfg-flakes.nix-apple-fonts.default;

        smfc = super.python3Packages.buildPythonApplication rec {
          pname = "smfc";
          version = "6.5.0";
          pyproject = true;

          src = super.fetchFromGitHub {
            owner = "petersulyok";
            repo = "smfc";
            tag = "v${version}";
            hash = "sha256-SkxV5hlNudEp+f+cysRgS623Ayibxp12nRYNuvSDRv4=";
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
    (import ../../pkg/searxng/overlay.nix)
  ];
}
