{ config, lib, cfg-meta, ... }:

let
  cfg = config.smind.age;
  hasMasterIdentity = cfg.masterIdentity.identity != null && cfg.masterIdentity.pubkey != null;

  # Load owner's secrets directly
  owner = config.smind.host.owner;
  group = if cfg-meta.isLinux then "users" else "staff";
  secretsFile = "${cfg-meta.paths.secrets}/${owner}/age-secrets.nix";
  loadOwnerSecrets = owner != null && cfg.enable && cfg.load-owner-secrets;
  ownerSecrets =
    if loadOwnerSecrets && builtins.pathExists secretsFile
    then import secretsFile { inherit cfg-meta owner group; }
    else {};
in
{

  options.smind.host.owner = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Primary owner/user of this host (e.g., 'pavel'). Used for loading user-specific secrets.";
  };

  options.smind.age.load-owner-secrets = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Whether to load owner-specific secrets based on smind.host.owner. Typically enabled on desktops, disabled on servers.";
  };

  options.smind.age.masterIdentity = {
    identity = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to the age identity file (e.g., /home/pavel/age-key.txt)";
    };

    pubkey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Public key corresponding to the identity";
    };
  };

  config = lib.mkMerge [
    # When masterIdentity is configured, enable age and set up rekey
    (lib.mkIf hasMasterIdentity {
      smind.age.enable = lib.mkDefault true;

      age.rekey = {
        masterIdentities = [
          {
            identity = cfg.masterIdentity.identity;
            pubkey = cfg.masterIdentity.pubkey;
          }
        ];
        storageMode = "local";
        localStorageDir = "${cfg-meta.paths.secrets}/rekeyed/${cfg-meta.hostname}";
      };
    })

    # Load owner-specific secrets
    (lib.mkIf loadOwnerSecrets {
      age.secrets = ownerSecrets;
    })

    # Dummy config when age is disabled - satisfies agenix-rekey requirements
    (lib.mkIf (!config.smind.age.enable) {
      age.rekey = {
        masterIdentities = [
          {
            identity = "/does-not-exist";
            pubkey = "age";
          }
        ];
        storageMode = "derivation";
      };
    })
  ];
}
