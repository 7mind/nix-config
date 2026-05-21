{ pkgs, smind-hm, cfg-meta, ... }:

{
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic.nix"
  ];

  smind.hm = {
    roles.server = true;

    # Headless build box, but still want the agent CLIs (claude-code,
    # codex, gemini-cli, opencode, yolo wrapper, …). The full bundle
    # normally rides in via roles.desktop; enable it directly here.
    dev.llm.enable = true;
  };

  programs.direnv = {
    config = {
      whitelist.prefix = [ "~/work" ];
    };
  };

  home.packages = with pkgs; [ ];
}
