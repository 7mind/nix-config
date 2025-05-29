{ pkgs, config, smind-hm, lib, extended_pkg, cfg-meta, inputs, outerConfig, import_if_exists, import_if_exists_or, ... }:

{
  imports = smind-hm.imports ++ [
    (import_if_exists_or "${cfg-meta.paths.secrets}/pavel/age-rekey.nix" (import "${cfg-meta.paths.modules}/age-dummy.nix"))
    (import_if_exists "${cfg-meta.paths.private}/modules/hm/pavel/cfg-hm.nix")
  ];

  smind.hm = {
    roles.desktop = true;
  };

  programs.direnv = {
    config = {
      whitelist.prefix = [ "~/work" ];
    };
  };

  home.packages = with pkgs; [
  ];

  programs.zsh.shellAliases = {
    rmj = "find . -depth -type d \\( -name target -or -name .bloop -or -name .bsp -or -name .metals \\) -exec rm -rf {} \\;";
  };

  /* programs.zed-editor =
    {
      userSettings = {
        base_keymap = "None";
      };
      userKeymaps = import ./zed-keymap/zed-keymap-linux.nix;
    };

    programs.vscode.profiles.default.keybindings =
    if cfg-meta.isLinux then
      (builtins.fromJSON (builtins.readFile "${cfg-meta.paths.users}/pavel/hm/keymap-vscode-linux.json"))
    else
      [ ];
  */

  # home.activation.jetbrains-keymaps = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  #   ${pkgs.findutils}/bin/find ${config.home.homeDirectory}/.config/JetBrains \
  #     -type d \
  #     -wholename '*/JetBrains/*/keymaps' '!' -path '*/settingsSync/*' \
  #     -exec cp -f "${cfg-meta.paths.users}/pavel/hm/keymap-idea-linux.xml" {}/Magen.xml \;
  # '';
}

