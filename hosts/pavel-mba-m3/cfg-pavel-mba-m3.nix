{ config, cfg-meta, cfg-const, ... }:

{
  smind = {
    darwin.sysconfig.enable = true;
    darwin.brew.enable = true;
    home-manager.enable = true;
  };

  networking.hostName = cfg-meta.hostname;

  system.primaryUser = "pavel";

  users.users.pavel = {
    home = "/Users/pavel";
    openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel;
  };

  system.defaults.screencapture = { location = "~/Desktop/Screenshots"; };

  home-manager.users.pavel = import ./home-pavel.nix;
}
