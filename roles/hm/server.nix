{ config, lib, ... }:

{
  options = {
    smind.hm.roles.server = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable server home-manager role with CLI tools";
    };
  };

  config = lib.mkIf config.smind.hm.roles.server {
    smind.hm = {
      htop.enable = lib.mkDefault true;
      ssh.enable = lib.mkDefault true;
      tmux.enable = lib.mkDefault true;

      zsh.enable = lib.mkDefault true;
      nushell.enable = lib.mkDefault true;

      cleanups.enable = lib.mkDefault true;
    };
  };
}
