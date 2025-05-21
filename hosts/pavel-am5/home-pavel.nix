{ pkgs, config, smind-hm, lib, extended_pkg, cfg-meta, xdg_associate, outerConfig, import_if_exists, ... }:

{
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.secrets}/pavel/age-rekey.nix"
    "${cfg-meta.paths.users}/pavel/hm/git.nix"
    (import_if_exists "${cfg-meta.paths.private}/modules/hm/pavel/cfg-hm.nix")
  ];

  age.rekey.hostPubkey = outerConfig.age.rekey.hostPubkey;

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

  xdg =
    (xdg_associate {
      schemes = [
        "application/pdf"
      ];
      desktopfile = "org.gnome.Evince.desktop";
    });

  programs.zed-editor =
    {
      userSettings = {
        base_keymap = "None";
      };
      userKeymaps = import ./zed-keymap/zed-keymap-linux.nix;
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
  programs.vscode.profiles.default.keybindings =
    if cfg-meta.isLinux then
      (builtins.fromJSON (builtins.readFile "${cfg-meta.paths.users}/pavel/hm/keymap-vscode-linux.json"))
    else
      [ ];

  programs.zsh.shellAliases = {
    rmj = "find . -depth -type d \\( -name target -or -name .bloop -or -name .bsp -or -name .metals \\) -exec rm -rf {} \\;";
    rmgpucache = "find ~ -name GPUCache -type d -exec rm -rf {} \\;";
    open =
      lib.mkIf cfg-meta.isLinux "xdg-open";
  };

  home.activation.createSymlinks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p .ssh/
    ln -sfn ${outerConfig.age.secrets.id_ed25519.path} ~/.ssh/id_ed25519
    ln -sfn ${outerConfig.age.secrets."id_ed25519.pub".path} ~/.ssh/id_ed25519.pub
    mkdir -p .sbt/secrets/
    ln -sfn ${outerConfig.age.secrets.nexus-oss-sonatype.path} ~/.sbt/secrets/credentials.sonatype-nexus.properties
  '';

  home.activation.jetbrains-keymaps = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${pkgs.findutils}/bin/find ${config.home.homeDirectory}/.config/JetBrains \
      -type d \
      -wholename '*/JetBrains/*/keymaps' '!' -path '*/settingsSync/*' \
      -exec cp -f "${cfg-meta.paths.users}/pavel/hm/keymap-idea-linux.xml" {}/Magen.xml \;
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
    cinny-desktop
    nheko

    bitwarden-desktop

    visualvm

    vlc
    telegram-desktop

    # https://github.com/NixOS/nixpkgs/issues/408853
    (winbox4.overrideAttrs (drv:
      {
        buildInputs = drv.buildInputs ++ [ pkgs.makeWrapper ];
        postFixup = ''
          wrapProgram $out/bin/WinBox --set "QT_QPA_PLATFORM" "xcb"
        '';
      }))

    # winbox4

    (extended_pkg {
      pkg = jetbrains.idea-ultimate;
      path = "bin/idea-ultimate";
      paths = [
        nodejs_24
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
        gccStdenv.cc.cc.lib
      ];
      #defs = { TEST = "1"; };
    })

    (extended_pkg {
      pkg = jetbrains.rider;
      path = "bin/rider";
      paths = [
        dotnet-sdk_9
        nodejs_24
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
      paths = [
        nodejs_24
      ];

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

