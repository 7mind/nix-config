{ config, lib, cfg-meta, ... }:

let
  cfg = config.smind.age;
  # Runtime path for TPM-decrypted master key (setup script writes here)
  defaultIdentityPath = if cfg-meta.isLinux then "/dev/shm/age-master-key" else "/tmp/age-master-key";
  hasMasterIdentity = cfg.masterIdentity.pubkey != null;

  # Load owner's secrets directly
  owner = config.smind.host.owner;
  group = if cfg-meta.isLinux then "users" else "staff";
  secretsFile =
    if cfg.secretsFile != null
    then cfg.secretsFile
    else "${cfg-meta.paths.secrets}/${owner}/age-secrets.nix";
  loadOwnerSecrets = owner != null && cfg.enable && cfg.load-owner-secrets;
  ownerSecrets =
    if loadOwnerSecrets && builtins.pathExists secretsFile
    then import secretsFile { inherit cfg-meta owner group; }
    else {};
  hostPubkey = config.age.rekey.hostPubkey;
  # agenix-rekey's "not yet configured" placeholder; treat as unset here.
  agenixRekeyDummyPubkey = "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq";
  hostPubkeySet = hostPubkey != null && hostPubkey != "" && hostPubkey != agenixRekeyDummyPubkey;
  hostPubkeyPattern = "^ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI[0-9A-Za-z+/]+={0,3}$";
in
{
  options.smind.age.load-owner-secrets = lib.mkEnableOption "loading of owner-specific secrets based on smind.host.owner. Typically enabled on desktops, disabled on servers";
  options.smind.age.secretsFile = lib.mkOption {
    type = lib.types.nullOr (lib.types.either lib.types.path lib.types.str);
    default = null;
    description = "Override the owner secret definition file loaded when smind.age.load-owner-secrets is enabled.";
  };

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
    {
      assertions = [
        {
          assertion = !hostPubkeySet || builtins.match hostPubkeyPattern hostPubkey != null;
          message = "age.rekey.hostPubkey must be exactly 'ssh-ed25519 <ed25519 base64 key blob>' with no prefix or suffix";
        }
      ];
    }
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

    # Fallback for hosts with age disabled or no master identity.
    # Empty masterIdentities so disabled hosts don't inject an invalid
    # dummy pubkey into the merged ageWrapper (breaks update-masterkeys).
    (lib.mkIf (!config.smind.age.enable || !hasMasterIdentity) {
      age.rekey = {
        masterIdentities = lib.mkDefault [];
        storageMode = lib.mkDefault "derivation";
      };
    })
  ];
}
