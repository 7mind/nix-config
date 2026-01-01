{ pkgs, config, smind-hm, lib, extended_pkg, cfg-meta, xdg_associate, outerConfig, import_if_exists, import_if_exists_or, ... }:

{
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic.nix"
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic-linux.nix"
  ];


  smind.hm = {
    roles.desktop = true;
    desktop.cosmic.minimal-keybindings = true;

    autostart.programs = with pkgs; [
      {
        name = "element-main";
        exec = "${element-desktop}/bin/element-desktop --hidden";
      }
      {
        name = "element-2nd";
        exec = "${element-desktop}/bin/element-desktop --hidden --profile secondary";
      }
      {
        name = "slack";
        exec = "${slack}/bin/slack -u";
      }
      {
        name = "bitwarden";
        exec = "${bitwarden-desktop}/bin/bitwarden";
      }
    ];
  };



  xdg = (lib.mkMerge [
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



  #  qtWrapperArgs+=(--set "QT_SCALE_FACTOR" "1")
  #  qtWrapperArgs+=(--set "QT_QPA_PLATFORM" "xcb")

}

