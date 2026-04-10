{ config, lib, pkgs, ... }:

let
  cfg = config.smind.infra.attic-cache;

  log = "${pkgs.util-linux}/bin/logger -t attic-push";

  inhibitFile = "/tmp/attic-push-inhibit";

  atticConfigSnippet = ''
    TOKEN=$(cat ${cfg.push.tokenFile}) || { ${log} -p user.err "failed to read token"; exit 1; }
    export ATTIC_CONFIG_DIR=$(mktemp -d)
    trap 'rm -rf "$ATTIC_CONFIG_DIR"' EXIT
    cat > "$ATTIC_CONFIG_DIR/config.toml" <<TOML
default-server = "nas"
[servers.nas]
endpoint = "${cfg.server-url}"
token = "$TOKEN"
TOML
  '';

  pushScript = pkgs.writeShellScript "attic-post-build-hook" ''
    set -f
    export IFS=' '
    # When the inhibit file exists, a bulk push will happen later (e.g. from ./setup)
    [[ -f ${inhibitFile} ]] && exit 0
    (
      ${atticConfigSnippet}
      OUTPUT=$(${pkgs.attic-client}/bin/attic push nas:${cfg.cache-name} $OUT_PATHS 2>&1) || ${log} -p user.warning "push failed for $OUT_PATHS: $OUTPUT"
      ${log} -p user.info "$OUTPUT"
    ) &
    disown
  '';

  # Script to push a full closure to attic, used by ./setup after building
  bulkPushScript = pkgs.writeShellScriptBin "attic-push-closure" ''
    set -euo pipefail
    if [[ $# -eq 0 ]]; then
      echo "Usage: attic-push-closure STORE_PATH..." >&2
      exit 1
    fi
    ${atticConfigSnippet}
    ${log} -p user.info "bulk push: $*"
    ${pkgs.attic-client}/bin/attic push nas:${cfg.cache-name} "$@" 2>&1 | while IFS= read -r line; do
      echo "$line"
      ${log} -p user.info "$line"
    done
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
      default = "main:EF5cnoxTpeY23deCWlU5ywj32Wf+nOL483aMq2OC14Q=";
      description = "Public signing key of the attic cache";
    };

    push = {
      enable = lib.mkEnableOption "automatic push to attic cache after every build";

      tokenFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to a file containing the attic admin token (e.g. agenix secret path)";
      };

      signingKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to the nix signing private key file. All locally-built paths will be signed with this key, enabling nix copy between hosts.";
      };

      signing-public-key = lib.mkOption {
        type = lib.types.str;
        default = "nix-local-1:Jbd41O4qAnV054TYjgERVAeu6Rh5R3F4RXyK6sQY5Uw=";
        description = "Public key corresponding to signingKeyFile. Added to trusted-public-keys so other hosts accept signed paths.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = [ pkgs.attic-client ];

      nix.settings = {
        substituters = [ "${cfg.server-url}/${cfg.cache-name}" ];
        trusted-public-keys = [ cfg.public-key cfg.push.signing-public-key ];
        # Fall back to building locally when attic is unreachable
        fallback = true;
        connect-timeout = 3;
      };
    }

    (lib.mkIf cfg.push.enable {
      nix.settings = {
        post-build-hook = pushScript;
        secret-key-files = [ cfg.push.signingKeyFile ];
      };

      environment.systemPackages = [ bulkPushScript ];
    })
  ]);
}
