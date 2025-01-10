{ pkgs, lib, config, ... }: {

  home.stateVersion = "25.05";

  imports = [
    ./modules/hm/htop.nix
    ./modules/hm/ssh.nix
    ./modules/hm/tmux.nix
    ./modules/hm/zsh.nix
  ];
}

