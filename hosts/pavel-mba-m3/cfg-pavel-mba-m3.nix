{ config, cfg-meta, import_if_exists, cfg-const, import_if_exists_or, ... }:

{
  imports =
    [
      (import_if_exists_or "${cfg-meta.paths.secrets}/pavel/age-rekey.nix" (import "${cfg-meta.paths.modules}/age-dummy.nix"))
    ];

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
