{ config, lib, pkgs, cfg-meta, ... }:

{
  options = {
    smind.hm.roles.server = lib.mkEnableOption "server home-manager role with CLI tools";
  };

  config = lib.mkIf config.smind.hm.roles.server {
    smind.hm = {
      htop.enable = lib.mkDefault true;
      ssh.enable = lib.mkDefault true;
      tmux.enable = lib.mkDefault true;

      zsh.enable = lib.mkDefault true;

      cleanups.enable = lib.mkDefault true;
    };

    # Oracle Cloud Infrastructure CLI (x86 Linux only).
    home.packages = lib.optional (
      pkgs.stdenv.hostPlatform.isLinux && pkgs.stdenv.hostPlatform.isx86
    ) pkgs.oci-cli;
  };
}
