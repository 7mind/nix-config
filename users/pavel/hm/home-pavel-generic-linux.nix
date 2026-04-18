{ lib, pkgs, xdg_associate, cfg-meta, config, import_if_exists, import_if_exists_or, ... }:

{
  programs.vscode.profiles.default.keybindings =
    if cfg-meta.isLinux then
      (builtins.fromJSON (builtins.readFile "${cfg-meta.paths.users}/pavel/hm/keymap-vscode-linux.json"))
    else
      [ ];

  home.activation.jetbrains-keymaps = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ -d "${config.home.homeDirectory}/.config/JetBrains" ]; then
      ${pkgs.findutils}/bin/find ${config.home.homeDirectory}/.config/JetBrains \
        -type d \
        -wholename '*/JetBrains/*/keymaps' '!' -path '*/settingsSync/*' \
        -exec cp -f "${cfg-meta.paths.users}/pavel/hm/keymap-idea-linux.xml" {}/Magen.xml \;
    fi
  '';


  smind.hm.zed.uiFontSize = 16;
  smind.hm.zed.bufferFontSize = 14;

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

  smind.hm.megasync = {
    enable = true;
    gnomeTheme.enable = true;
    dev.llm.fullscreenTui.enable = false;
  };

  home.pointerCursor = {
    # Disable dconf cursor settings - managed at system level with lockAll
    gtk.enable = lib.mkForce false;
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
    dev.jetbrains.enable = true;
    desktop.cosmic.minimal-keybindings = true;

    autostart.programs = [
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
    fractal

    bitwarden-desktop

    visualvm

    vlc

    winbox-quirk

    mqttx
  ];

}
