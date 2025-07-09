{ pkgs, config, smind-hm, lib, extended_pkg, cfg-meta, inputs, outerConfig, import_if_exists, import_if_exists_or, ... }:

{
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic.nix"
  ];

  smind.hm = {
    roles.desktop = true;
  };

  programs.direnv = {
    config = {
      whitelist.prefix = [ "~/work" ];
    };
  };

  home.sessionVariables = {
    OLLAMA_API_BASE = "http://127.0.0.1:11434";
    AIDER_DARK_MODE = "true";
  };

  home.packages = with pkgs; [
    aider-chat
    python3
    claude-code
  ];
}

