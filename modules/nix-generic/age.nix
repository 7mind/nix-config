{ config, lib, cfg-meta, ... }:

let
  cfg = config.smind.age;
  # Runtime path for TPM-decrypted master key (setup script writes here)
  defaultIdentityPath = if cfg-meta.isLinux then "/dev/shm/age-master-key" else "/tmp/age-master-key";
  hasMasterIdentity = cfg.masterIdentity.pubkey != null;

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
  options.smind.age.load-owner-secrets = lib.mkEnableOption "loading of owner-specific secrets based on smind.host.owner. Typically enabled on desktops, disabled on servers";

  options.smind.age.masterIdentity = {
    identity = lib.mkOption {
      type = lib.types.str;
      default = defaultIdentityPath;
      description = "Path to the age identity file. Defaults to /dev/shm/age-master-key (Linux) or /tmp/age-master-key (Darwin). The setup script decrypts the TPM-protected key to this location at runtime.";
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

    # Dummy config when age is disabled or no master identity - satisfies agenix-rekey requirements
    (lib.mkIf (!config.smind.age.enable || !hasMasterIdentity) {
      age.rekey = {
        masterIdentities = lib.mkDefault [
          {
            identity = "/does-not-exist";
            pubkey = "age";
          }
        ];
        storageMode = lib.mkDefault "derivation";
      };
    })
  ];
}
