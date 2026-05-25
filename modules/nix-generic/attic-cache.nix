{ config, lib, pkgs, ... }:

let
  cfg = config.smind.infra.attic-cache;

  log = "${pkgs.util-linux}/bin/logger -t attic-push";

  inhibitDir = "/run/attic-push";
  inhibitFile = "${inhibitDir}/inhibit";

  atticConfigSnippet = ''
    TOKEN=$(cat ${cfg.push.tokenFile}) || { ${log} -p user.err "failed to read token"; exit 1; }
    export XDG_CONFIG_HOME=$(mktemp -d)
    trap 'rm -rf "$XDG_CONFIG_HOME"' EXIT
    mkdir -p "$XDG_CONFIG_HOME/attic"
    cat > "$XDG_CONFIG_HOME/attic/config.toml" <<TOML
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
      OUTPUT=$(${pkgs.attic-client}/bin/attic push -j 16 nas:${cfg.cache-name} $OUT_PATHS 2>&1) || ${log} -p user.warning "push failed for $OUT_PATHS: $OUTPUT"
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
    ${pkgs.attic-client}/bin/attic push -j 16 nas:${cfg.cache-name} "$@" 2>&1 | while IFS= read -r line; do
      echo "$line"
      ${log} -p user.info "$line"
    done
  '';
in
{
  options.smind.infra.attic-cache = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Trust the attic cache's signing keys (substituter usage is gated
        separately by `substituter.enable`). Defaults to `true` so every host
        accepts SSH-pushed / `nix copy` paths signed by other hosts in the
        fleet; turn it off only for hosts that must reject those signatures.
      '';
    };

    substituter.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Add the attic server as a nix substituter. Requires `enable = true`.
        Set to `false` on hosts that cannot reach the attic server directly
        (e.g. Oracle Cloud hosts off the home LAN); they still benefit from
        `enable = true` to accept signed paths pushed over SSH.
      '';
    };

    server-url = lib.mkOption {
      type = lib.types.str;
      default = "http://attic.home.7mind.io:8080";
      description = "Base URL of the attic server";
    };

    cache-name = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Name of the attic cache";
    };

    legacy-public-keys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        # Pre-`nix-local-1`-unification server key — the auto-generated
        # keypair attic used for the `main` cache before we pinned it to
        # `nix-local-1`. Kept trusted so old NARs in the cache stay
        # substitutable until they age out. Only one entry is meaningful:
        # nix's signature verifier picks the FIRST trusted-public-key
        # whose name matches a sig and silently shadows the rest, so
        # listing multiple `main:` keys is pointless.
        "main:Gge5eS7kanH8x7flmWuv1zFEA4aZ+RpBwkTKlphdgX4="
      ];
      description = ''
        Legacy public keys of the attic cache. Trusted so NARs signed with
        prior server-generated keypairs remain usable while they linger in
        the store. New paths are signed with `signing-public-key`.
      '';
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

      nix.settings.trusted-public-keys = [ cfg.push.signing-public-key ] ++ cfg.legacy-public-keys;
    }

    (lib.mkIf cfg.substituter.enable {
      nix.settings = {
        substituters = [ "${cfg.server-url}/${cfg.cache-name}" ];
        # Fall back to building locally when attic is unreachable
        fallback = true;
        connect-timeout = 3;
      };
    })

    (lib.mkIf cfg.push.enable {
      nix.settings = {
        post-build-hook = pushScript;
        secret-key-files = [ cfg.push.signingKeyFile ];
      };

      environment.systemPackages = [ bulkPushScript ];
    })
  ]);
}
