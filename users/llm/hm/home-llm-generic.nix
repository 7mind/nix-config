{ smind-hm, outerConfig, ... }:

{
  imports = smind-hm.imports;

  smind.hm = {
    roles.server = true;

    dev.llm.enable = true;
    # The llm user is a service identity, not an author — don't tag commits
    # with a Co-Authored-By trailer pointing at it.
    dev.llm.coAuthored.enable = false;

    # Pass the agenix-managed SSH key path through to yolo so the wrapper
    # can ro-bind it into the bubblewrap sandbox.
    dev.llm.llmSshKeyPath = outerConfig.smind.roles.server.llm-worker.sshKey.path;
  };

  programs.direnv.config.whitelist.prefix = [ "~/work" ];
}
