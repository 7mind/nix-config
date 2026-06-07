{ lib, pkgs, cfg-meta, import_if_exists, ... }:

{
  imports = [
    (import_if_exists "${cfg-meta.paths.private}/users/pavel/hm/home-pavel-generic-private.nix")
  ];

  home.shellAliases = { };

  programs.zsh.shellAliases = {
    rmj = "find . -depth -type d \\( -name target -or -name .bloop -or -name .bsp -or -name .metals \\) -exec rm -rf {} \\;";
    rmgpucache = "${pkgs.findutils}/bin/find ~ -name GPUCache -type d -exec rm -rf {} \\;";
    open =
      lib.mkIf cfg-meta.isLinux "xdg-open";
  };

  programs.nushell.extraConfig = ''
    def rmj [] {
      glob --no-file --no-symlink "**/{target,.bloop,.bsp,.metals}" | each {|dir| rm -rf $dir }
    }
  '';

  programs.nushell.shellAliases = { };
}
