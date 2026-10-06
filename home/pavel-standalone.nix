{ lib, smind-hm, ... }:
{
  imports = smind-hm.imports ++ [
    ../users/pavel/hm/home-pavel-generic.nix
  ];

  config = {
    smind.hm = {
      roles.server = true;
      cleanups.enable = lib.mkForce false;
      dev.generic.enable = true;
      dev.git.enable = true;
      dev.git.rewriteGithubToSsh = false;
    };

    services.ssh-agent.enable = lib.mkForce false;
  };
}
