{ config, cfg-meta, import_if_exists, cfg-const, ... }:

{
  imports =
    [
      "${cfg-meta.paths.secrets}/pavel/age-rekey.nix"
      "${cfg-meta.paths.secrets}/pavel/age-secrets.nix"
    ];

  smind = {
    darwin.sysconfig.enable = true;
    darwin.brew.enable = true;
    home-manager.enable = true;
  };

  age.rekey = {
    hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIEyccdZT7PcV6PpudcAoYsBlQW03L4PAjAwTP/b+rGY";
  };



  users.users.pavel = {
    home = "/Users/pavel";
    openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel;
  };

  system.defaults.screencapture = { location = "~/Desktop/Screenshots"; };

  home-manager.users.pavel = import ./home-pavel.nix;
}
