{ config, lib, ... }:

let
  cfg = config.smind.infra.attic-cache;
in
{
  config = lib.mkIf cfg.enable {
    # SetGID + group-write + no sticky so any user in `users` can create
    # and remove the inhibit file (e.g. from ./setup). The path is the
    # parent of `inhibitFile` defined in modules/nix-generic/attic-cache.nix.
    systemd.tmpfiles.rules = [
      "d /run/attic-push 2775 root users -"
    ];
  };
}
