{ lib, pkgs, xdg_associate, extended_pkg, cfg-meta, config, import_if_exists, import_if_exists_or, ... }:

{
  programs.vscode.profiles.default.keybindings =
    if cfg-meta.isLinux then
      (builtins.fromJSON (builtins.readFile "${cfg-meta.paths.users}/pavel/hm/keymap-vscode-linux.json"))
    else
      [ ];

  home.activation.jetbrains-keymaps = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${pkgs.findutils}/bin/find ${config.home.homeDirectory}/.config/JetBrains \
      -type d \
      -wholename '*/JetBrains/*/keymaps' '!' -path '*/settingsSync/*' \
      -exec cp -f "${cfg-meta.paths.users}/pavel/hm/keymap-idea-linux.xml" {}/Magen.xml \;
  '';


  programs.zed-editor =
    {
      userSettings = {
        base_keymap = "None";
      };
      userKeymaps =
        (builtins.fromJSON (builtins.readFile "${cfg-meta.paths.users}/pavel/hm/keymap-zed-linux.json"));
    };


  # json 2 nix:
  # nix eval --impure --expr 'builtins.fromJSON (builtins.readFile ./my-file.json)' --json
  # nix eval --impure --expr "builtins.fromJSON (builtins.readFile ./vscode-keymap-linux-editorFocus.json)"  > vscode-keymap-linux-editorFocus.nix
  # nix run nixpkgs#nixfmt-classic ./vscode-keymap-linux-editorFocus.nix

  services.megasync.enable = true;
  services.megasync.package = (pkgs.megasync.overrideAttrs (drv:
    {
      buildInputs = drv.buildInputs ++ [ pkgs.makeWrapper ];
      preFixup = ''
        ${drv.preFixup}
         qtWrapperArgs+=(--set "QT_STYLE_OVERRIDE" "adwaita")
         qtWrapperArgs+=(--set "DO_NOT_UNSET_XDG_SESSION_TYPE" "1")
      '';
    }));


  home.pointerCursor = {
    gtk.enable = true;
    x11.enable = true;
    package = pkgs.adwaita-icon-theme;
    name = "Adwaita";
    size = 32;
  };

  programs.direnv = {
    config = {
      whitelist.prefix = [ "~/work" ];
    };
  };

  xdg = (lib.mkMerge [
    (xdg_associate {
      schemes = [
        "application/pdf"
      ];
      desktopfile = "org.gnome.Evince.desktop";
    })

    {
      desktopEntries = {
        element-desktop-2 = {
          exec = "${pkgs.element-desktop.out}/bin/element-desktop --profile secondary %u";
          genericName = "Element Desktop 2nd";
          icon = "element";
          mimeType = [ "x-scheme-handler/element" "x-scheme-handler/io.element.desktop" ];
          name = "Element Desktop 2nd";
          type = "Application";
        };
      };
    }
  ]);


  smind.hm = {
    roles.desktop = true;
    desktop.cosmic.minimal-keybindings = true;

    autostart.programs = [
      # {
      #   name = "element-main";
      #   exec = "${config.home.profileDirectory}/bin/element-desktop";
      # }
      # {
      #   name = "element-main";
      #   exec = "${element-desktop}/bin/element-desktop --hidden";
      # }
      # {
      #   name = "element-2nd";
      #   exec = "${element-desktop}/bin/element-desktop --hidden --profile secondary";
      # }
      {
        name = "slack";
        exec = "${config.home.profileDirectory}/bin/slack -u";
      }
      {
        name = "fractal";
        exec = "${config.home.profileDirectory}/bin/fractal --minimized";
      }
    ];
  };

  home.packages = with pkgs; [
    nordvpn-wireguard-extractor

    furmark
  ]
  ++ lib.optional (!config.smind.hm.electron-wrappers.element.enable) element-desktop
  ++ [
    fractal-tray

    bitwarden-desktop

    visualvm

    vlc

    winbox-quirk

    mqttx

    (extended_pkg {
      pkg = jetbrains.idea;
      path = "bin/idea";
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
        zstd
      ];
      #defs = { TEST = "1"; };
    })


    (extended_pkg {
      pkg = jetbrains.webstorm;
      path = "bin/webstorm";
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
    })

    (extended_pkg {
      pkg = jetbrains.pycharm;
      path = "bin/pycharm";
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
        zstd
      ];
    })

    (extended_pkg {
      pkg = jetbrains.datagrip;
      path = "bin/datagrip";
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
        zstd
      ];
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
        zstd
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
        # qt6.full
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
        zstd
      ];
      defs = {
        CMAKE_LIBRARY_PATH = lib.makeLibraryPath ld-libs;
        CMAKE_INCLUDE_PATH = lib.makeIncludePath ld-libs;
        # CMAKE_PREFIX_PATH = "${qt6.full}";
      };
    })
  ];

}
