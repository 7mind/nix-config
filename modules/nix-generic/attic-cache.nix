{ config, lib, pkgs, ... }:

let
  cfg = config.smind.infra.attic-cache;

  pushScript = pkgs.writeShellScript "attic-post-build-hook" ''
    set -f
    export IFS=' '
    export ATTIC_CONFIG_DIR=$(mktemp -d)
    trap 'rm -rf "$ATTIC_CONFIG_DIR"' EXIT
    TOKEN=$(cat ${cfg.push.tokenFile}) || exit 0
    ${pkgs.attic-client}/bin/attic login nas ${cfg.server-url} "$TOKEN" 2>/dev/null || exit 0
    ${pkgs.attic-client}/bin/attic push nas:${cfg.cache-name} $OUT_PATHS 2>/dev/null || true
  '';
in
{
  options.smind.infra.attic-cache = {
    enable = lib.mkEnableOption "use attic binary cache on nas as a nix substituter";

    server-url = lib.mkOption {
      type = lib.types.str;
      default = "http://nas.home.7mind.io:8080";
      description = "Base URL of the attic server";
    };

    cache-name = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Name of the attic cache";
    };

    public-key = lib.mkOption {
      type = lib.types.str;
      default = "nas.home.7mind.io-1:0yzrMlTWAoq2aGTXCQ+jurDEB1r8X5phENygSRz7PwY=";
      description = "Public signing key of the attic cache";
    };

    push = {
      enable = lib.mkEnableOption "automatic push to attic cache after every build";

      tokenFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to a file containing the attic admin token (e.g. agenix secret path)";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      nix.settings = {
        substituters = [ "${cfg.server-url}/${cfg.cache-name}" ];
        trusted-public-keys = [ cfg.public-key ];
      };
    }

    (lib.mkIf cfg.push.enable {
      nix.settings.post-build-hook = pushScript;
    })
  ]);
}
