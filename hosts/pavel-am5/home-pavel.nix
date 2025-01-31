{ pkgs, smind-hm, lib, extended_pkg, cfg-meta, inputs, nixosConfig, import_if_exists, ... }:

{
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.users}/pavel/hm/git.nix"
    "${cfg-meta.paths.secrets}/pavel/age-rekey.nix"
    inputs.agenix-rekey.homeManagerModules.default
    (import_if_exists "${cfg-meta.paths.private}/pavel/cfg-hm.nix")
  ];

  smind.hm = {
    roles.desktop = true;
    firefox.sync-username = "pshirshov@gmail.com";
    autostart.programs = with pkgs; [
      {
        name = "element";
        exec = "${element-desktop}/bin/element-desktop --hidden";
      }
      {
        name = "slack";
        exec = "${slack}/bin/slack -u";
      }
      {
        name = "telegram-desktop";
        exec = "${pkgs.telegram-desktop}/bin/telegram-desktop -startintray";
      }
    ];
  };

  # Developer: toggle keyboard shortcuts troubleshootinga
  # https://github.com/jbro/vscode-default-keybindings
  # https://github.com/codebling/vs-code-default-keybindings
  # negate all defaults:
  # - sed 's/\/\/.*//' ./vscode-keymap/reference-keymap/linux.negative.keybindings.json > ./vscode-keymap/linux/vscode-keymap-linux-negate.json
  # select defaults where .when is unset
  # - sed 's/\/\/.*//' ./vscode-keymap/reference-keymap/linux.keybindings.raw.json | jq '[ .[] | select( (.when? | not) ) ]' > ./vscode-keymap/linux/vscode-keymap-linux-.json
  # select defaults where .when contains
  # sed 's/\/\/.*//' ./vscode-keymap/reference-keymap/linux.keybindings.raw.json | jq '[ .[] | select( ((.when? and (.when | contains("editorTextFocus"))) )) ]' > ./vscode-keymap/linux/vscode-keymap-linux-.json
  # json 2 nix:
  # nix eval --impure --expr 'builtins.fromJSON (builtins.readFile ./my-file.json)' --json
  # nix eval --impure --expr "builtins.fromJSON (builtins.readFile ./vscode-keymap-linux-editorFocus.json)"  > vscode-keymap-linux-editorFocus.nix
  # nix run nixpkgs#nixfmt-classic ./vscode-keymap-linux-editorFocus.nix
  programs.vscode.keybindings =
    if cfg-meta.isLinux then
      (
        let
          attemptJson = path:
            if builtins.pathExists path
            then builtins.fromJSON (builtins.readFile path)
            else null;

          attemptNix = path:
            if builtins.pathExists path
            then import path
            else null;

          firstNonNull = list:
            builtins.foldl' (acc: x: if acc != null then acc else x) null list;

          readCfg = f: firstNonNull [
            (attemptJson ./vscode-keymap/linux/vscode-keymap-linux-${f}.json)
            (attemptNix  ./vscode-keymap/linux/vscode-keymap-linux-${f}.nix)
            (attemptJson ./vscode-keymap/linux/negate/vscode-keymap-linux-${f}.json)
          ];

          imports = [
            "!negate-all"
            "!negate-gitlens"
            "custom"
            "textInputFocus"
            "listFocus"
            "editorFocus"
          ];
          allKeys = builtins.map readCfg imports;
          flattened = builtins.concatLists allKeys;

          processList = objs:
            builtins.concatMap
              (obj:
                let
                  key = obj.key;

                  m1 = builtins.match ''^ctrl\+(.)[[:space:]]+ctrl\+(.)$'' key;
                  m2 = builtins.match ''^ctrl\+\\[(.+)\\][[:space:]]+ctrl\+\\[(.+)\\]$'' key;

                  transformed =
                    if m1 != null then
                      let
                        A = builtins.elemAt m1 0;
                        B = builtins.elemAt m1 1;
                        newKey = ''ctrl+${A} ${B}'';
                        result = [ obj (obj // { key = newKey; }) ];
                      in
                      builtins.trace result result
                    else if m2 != null then
                      let
                        KeyA = builtins.elemAt m2 0;
                        KeyB = builtins.elemAt m2 1;
                        newKey = ''ctrl+[${KeyA}] [${KeyB}]'';
                        result = [ obj (obj // { key = newKey; }) ];
                      in
                      builtins.trace result result
                    else
                      [ obj ];
                in
                if (lib.hasPrefix "-" obj.command) then [ obj ] else transformed
              )
              objs;
        in
        (processList flattened)
      )
    else
      if cfg-meta.isDarwin then [ ] else
      [ ];

  programs.zsh.shellAliases = {
    rmj = "find . -depth -type d \\( -name target -or -name .bloop -or -name .bsp -or -name .metals \\) -exec rm -rf {} \\;";
    rmgpucache = "find ~ -name GPUCache -type d -exec rm -rf {} \\;";
    open =
      lib.mkIf cfg-meta.isLinux "xdg-open";
  };

  home.activation.createSymlinks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p .ssh/
    ln -sfn ${nixosConfig.age.secrets.id_ed25519.path} ~/.ssh/id_ed25519
    ln -sfn ${nixosConfig.age.secrets."id_ed25519.pub".path} ~/.ssh/id_ed25519.pub

    mkdir -p .sbt/secrets/
    ln -sfn ${nixosConfig.age.secrets.nexus-oss-sonatype.path} ~/.sbt/secrets/credentials.sonatype-nexus.properties
  '';


  programs.direnv = {
    config = {
      whitelist.prefix = [ "~/work" ];
    };
  };

  services.megasync.enable = true;
  services.megasync.package = (pkgs.megasync.overrideAttrs (drv:
    {
      buildInputs = drv.buildInputs ++ [ pkgs.makeWrapper ];
      preFixup = ''
        ${drv.preFixup}
         qtWrapperArgs+=(--set "QT_STYLE_OVERRIDE" "adwaita")
         qtWrapperArgs+=(--set "DO_NOT_UNSET_XDG_SESSION_TYPE" "1")
         qtWrapperArgs+=(--set "QT_SCALE_FACTOR" "1")
         qtWrapperArgs+=(--set "QT_QPA_PLATFORM" "xcb")
      '';
    }));

  home.packages = with pkgs; [
    element-desktop
    bitwarden-desktop

    visualvm

    vlc
    telegram-desktop


    (extended_pkg {
      pkg = jetbrains.idea-ultimate;
      path = "bin/idea-ultimate";
      ld-libs = [
        libmediainfo
        xorg.libX11
        xorg.libX11.dev
        xorg.libICE
        xorg.libSM

        libGL
        icu
        fontconfig
        gccStdenv.cc.cc.lib
      ];
      #defs = { TEST = "1"; };
    })

    (extended_pkg {
      pkg = jetbrains.rider;
      path = "bin/rider";
      paths = [
        dotnet-sdk_9
      ];
      ld-libs = [
        libmediainfo
        xorg.libX11
        xorg.libX11.dev
        xorg.libICE
        xorg.libSM

        libGL
        icu
        fontconfig
      ];
    })

    (extended_pkg rec {
      pkg = jetbrains.clion;
      path = "bin/clion";
      ld-libs = [
        libGL
        libglvnd
        libGLU
        qt6.full
        vulkan-headers
        boost

        libxkbcommon

        libmediainfo
        xorg.libX11
        xorg.libX11.dev
        xorg.libICE
        xorg.libSM

        icu
        fontconfig
      ];
      defs = {
        CMAKE_LIBRARY_PATH = lib.makeLibraryPath ld-libs;
        CMAKE_INCLUDE_PATH = lib.makeIncludePath ld-libs;
        CMAKE_PREFIX_PATH = "${qt6.full}";
      };
    })
  ];

}

