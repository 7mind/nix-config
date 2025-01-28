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

  # https://github.com/jbro/vscode-default-keybindings
  # https://github.com/codebling/vs-code-default-keybindings
  # - sed 's/\/\/.*//' ./reference-keymap/linux.keybindings.raw.json > ./vscode-keymap-linux-negate.json
  # filters:
  # - sed 's/\/\/.*//' ./reference-keymap/linux.negative.keybindings.json | jq '[ .[] | select( (.when? and (.when | contains("textInputFocus")) | not) or (.when? | not) ) ]' > vscode-keymap-linux-negate.json
  # - sed 's/\/\/.*//' ./reference-keymap/linux.negative.keybindings.json | jq '[ .[] | select( ((.when? and (.when | contains("textInputFocus"))) or (not .when?) )) ]' > vscode-keymap-linux.json
  programs.vscode.keybindings =
    if cfg-meta.isLinux then (builtins.fromJSON (builtins.readFile ./vscode-keymap-linux-negate.json)) ++ (builtins.fromJSON (builtins.readFile ./vscode-keymap-linux.json)) else
    if cfg-meta.isDarwin then (builtins.fromJSON (builtins.readFile ./vscode-keymap-mac-negate.json)) ++ (builtins.fromJSON (builtins.readFile ./vscode-keymap-mac.json)) else
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

