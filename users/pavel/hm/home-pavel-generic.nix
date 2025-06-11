{ lib, pkgs, cfg-meta, import_if_exists, import_if_exists_or, ... }:

{
  imports = [
    (import_if_exists "${cfg-meta.paths.private}/users/pavel/hm/home-pavel-generic-private.nix")
    (import_if_exists_or "${cfg-meta.paths.secrets}/pavel/age-rekey.nix" (import "${cfg-meta.paths.modules}/age-dummy.nix"))
  ];

  home.activation.aider-config =
    let
      cfg = pkgs.writeText "example.yaml" (pkgs.lib.generators.toYAML { } [
        { name = "ollama_chat/devstral:24b"; extra_params = { num_ctx = 131072; }; }
        { name = "ollama_chat/qwen2.5-coder:32b"; extra_params = { num_ctx = 65535; }; }
      ]);
    in
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ln -sfn ${cfg} ~/.aider.model.settings.yml
    '';

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
