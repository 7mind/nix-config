{ config, lib, ... }:

let
  cfg = config.smind.infra.attic-cache;
in
{
  options.smind.infra.attic-cache = {
    enable = lib.mkEnableOption "use attic binary cache on nas as a nix substituter";

    url = lib.mkOption {
      type = lib.types.str;
      default = "http://nas.home.7mind.io:8080/main";
      description = "URL of the attic cache (including cache name)";
    };

    public-key = lib.mkOption {
      type = lib.types.str;
      default = "nas.home.7mind.io-1:0yzrMlTWAoq2aGTXCQ+jurDEB1r8X5phENygSRz7PwY=";
      description = "Public signing key of the attic cache";
    };
  };

  config = lib.mkIf cfg.enable {
    nix.settings = {
      substituters = [ cfg.url ];
      trusted-public-keys = [ cfg.public-key ];
    };
  };
}
