{ lib, pkgs, cfg-meta, import_if_exists, ... }:

{
  imports = [
    (import_if_exists "${cfg-meta.paths.private}/users/pavel/hm/home-pavel-generic-private.nix")
  ];

  # home.activation.aider-config =
  #   let
  #     cfg = pkgs.writeText "example.yaml" (pkgs.lib.generators.toYAML { } [
  #       { name = "ollama_chat/devstral:24b-small-2505-q8_0"; extra_params = { num_ctx = 131072; }; }
  #       { name = "ollama_chat/devstral:24b-small-2505-fp16"; extra_params = { num_ctx = 60000; }; }

  #       { name = "ollama_chat/qwen2.5:32b-instruct-q8_0"; extra_params = { num_ctx = 65535; }; }
  #       { name = "ollama_chat/qwen2.5-coder:32b-instruct-q8_0"; extra_params = { num_ctx = 65535; }; }
  #     ]);
  #   in
  #   lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  #     ln -sfn ${cfg} ~/.aider.model.settings.yml
  #   '';

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
