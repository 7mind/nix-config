{ config, lib, ... }:

{
  options = {
    smind.hm.roles.server = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.roles.server {
    smind.hm = {
      htop.enable = true;
      ssh.enable = true;
      tmux.enable = true;
      zsh.enable = true;
      cleanups.enable = true;
    };
  };
}
