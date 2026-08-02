{ pkgs, lib, config, ... }: {
  options = {
    smind.hw.uhk-keyboard.enable = lib.mkEnableOption "Ultimate Hacking Keyboard support";
  };

  config = lib.mkIf config.smind.hw.uhk-keyboard.enable {
    services.udev = {
      packages = with pkgs; [ uhk-udev-rules ];
    };

    # uhk-agent SmartMacroCopy copies bundled docs out of the nix store (dirs
    # mode 0555) into ~/.config/uhk-agent/smart-macro-docs, preserving source
    # modes. Inside SmartMacroCopy the sequence is:
    #   1. fs.cp(firmware/doc -> dest)          # creates dest as dr-xr-xr-x
    #   2. fs.cp(firmware/doc-dev -> dest/doc-dev)  # needs write on dest
    #   3. (later, outside Mi) chmod -R +w smart-macro-docs
    # Step 2 fails with EACCES on first launch; step 1's force-unlink fails on
    # every subsequent launch against the leftover 0555 tree. Either way the
    # unhandled rejection aborts before BrowserWindow is shown.
    #
    # Fix: patch Mi to chmod the dest writable before the first cp (covers a
    # leftover tree) and between the two cps (covers first launch). Keep a
    # launch wrapper as defense in depth for any other leftover 0555 state.
    # Upstream source fix: UltimateHackingKeyboard/agent#3024 (issues #2652, #2679).
    # nixpkgs packaging fix: NixOS/nixpkgs#548597. Drop this override once both
    # land and the packaged Agent release contains the source fix.
    environment.systemPackages = [
      (pkgs.uhk-agent.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
        postFixup = (old.postFixup or "") + ''
          substituteInPlace $out/opt/uhk-agent/app.asar.unpacked/electron-main.js \
            --replace-fail \
              'await(0,Pi.cp)(s,i,{force:!0,recursive:!0});const a=g().join(e.tmpDirectory,"doc-dev"),c=g().join(i,"doc-dev");await(0,Pi.cp)(a,c,{force:!0,recursive:!0}),t.misc("[SmartMacroCopy] done")' \
              'await Vi(i).catch(()=>{}),await(0,Pi.cp)(s,i,{force:!0,recursive:!0}),await Vi(i);const a=g().join(e.tmpDirectory,"doc-dev"),c=g().join(i,"doc-dev");await(0,Pi.cp)(a,c,{force:!0,recursive:!0}),t.misc("[SmartMacroCopy] done")'
          wrapProgram $out/bin/uhk-agent --run '
            docs="''${XDG_CONFIG_HOME:-$HOME/.config}/uhk-agent/smart-macro-docs"
            [ -d "$docs" ] && chmod -R u+w "$docs" || true
          '
        '';
      }))
    ];

    hardware = {
      keyboard.uhk.enable = true;
    };
  };

}
