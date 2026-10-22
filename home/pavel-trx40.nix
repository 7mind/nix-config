{
  pkgs,
  smind-hm,
  cfg-meta,
  ...
}:

{
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic.nix"
  ];

  smind.hm = {
    roles.server = true;

    # Headless build box, but still want the agent CLIs (claude-code,
    # codex, yolo wrapper, …). The full bundle
    # normally rides in via roles.desktop; enable it directly here.
    dev.llm.enable = true;
    dev.generic.enable = true;

    # Same omission as dev.llm above: git/tig/lazygit normally ride in via
    # roles.desktop, which this headless box does not use. Enable directly.
    # The SSH key on this host is not registered on GitHub and there is no
    # Secret Service (no keyring), so keep GitHub on HTTPS and do not use
    # the libsecret credential helper.
    dev.git.enable = true;
    dev.git.rewriteGithubToSsh = false;
    dev.git.credentialHelper = "";
  };

  # GitHub HTTPS auth via `gh`, as previously set up by hand in
  # ~/.gitconfig. That file must not come back: git ignores
  # ~/.config/git/config entirely while ~/.gitconfig exists, which would
  # shadow the Home Manager git configuration again.
  programs.git.settings.credential = {
    "https://github.com".helper = "!${pkgs.gh}/bin/gh auth git-credential";
    "https://gist.github.com".helper = "!${pkgs.gh}/bin/gh auth git-credential";
  };

  programs.direnv = {
    config = {
      whitelist.prefix = [ "~/work" ];
    };
  };

  home.packages = with pkgs; [ ];
}
