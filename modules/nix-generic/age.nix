{
  config,
  lib,
  cfg-meta,
  ...
}:

let
  cfg = config.smind.age;
  # Runtime path for TPM-decrypted master key (setup script writes here)
  defaultIdentityPath = if cfg-meta.isLinux then "/dev/shm/age-master-key" else "/tmp/age-master-key";
  hasMasterIdentity = cfg.masterIdentity.pubkey != null;

  # Load owner's secrets directly
  owner = config.smind.host.owner;
  group = if cfg-meta.isLinux then "users" else "staff";
  defaultSecretsFileFor = secretOwner: "${cfg-meta.paths.secrets}/${secretOwner}/age-secrets.nix";
  ownerSecretsFile = if cfg.secretsFile != null then cfg.secretsFile else defaultSecretsFileFor owner;
  loadSecretsFile =
    secretOwner: secretsFile:
    if builtins.pathExists secretsFile then
      import secretsFile {
        inherit cfg-meta group;
        owner = secretOwner;
      }
    else
      { };
  rekeyedUserSecrets =
    user:
    let
      secrets = loadSecretsFile user (defaultSecretsFileFor user);
      outputDir = "${cfg-meta.paths.secrets}/rekeyed/${cfg-meta.hostname}-${user}";
      pubkeyHash = builtins.hashString "sha256" hostPubkey;
      rekeyedSecretFor =
        name:
        let
          secret = builtins.getAttr name secrets;
          secretName = secret.name or name;
          identHash = builtins.substring 0 32 (
            builtins.hashString "sha256" (pubkeyHash + builtins.hashFile "sha256" secret.rekeyFile)
          );
        in
        builtins.removeAttrs secret [ "rekeyFile" ]
        // {
          file = "${outputDir}/${identHash}-${secretName}.age";
          name = "${user}/${secretName}";
        };
    in
    builtins.listToAttrs (
      map (name: {
        name = "${user}/${name}";
        value = rekeyedSecretFor name;
      }) (builtins.attrNames secrets)
    );
  loadOwnerSecrets = owner != null && cfg.enable && cfg.load-owner-secrets;
  ownerSecrets = if loadOwnerSecrets then loadSecretsFile owner ownerSecretsFile else { };
  loadAdditionalUserOnlySecrets = cfg.enable && cfg.additionalUserOnlySecrets != [ ];
  additionalUserOnlySecrets = builtins.foldl' (acc: user: acc // rekeyedUserSecrets user) { } (
    lib.unique cfg.additionalUserOnlySecrets
  );
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
  options.smind.age.additionalUserOnlySecrets = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Additional users whose pre-rekeyed secrets should be loaded into age.secrets under <user>/... keys.";
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
      lib.smind.age.userSecret =
        {
          hmConfig,
          outerConfig,
          ageSecrets ? outerConfig.age.secrets,
          user ? hmConfig.home.username,
        }:
        name:
        let
          userScopedName = "${user}/${name}";
        in
        if builtins.hasAttr userScopedName ageSecrets then
          builtins.getAttr userScopedName ageSecrets
        else
          builtins.getAttr name ageSecrets;

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

    # Load additional user-specific secrets under <user>/... keys for multi-user hosts.
    # These are not rekeyed by the system host target; each user rekeys their
    # own source secrets into private/secrets/rekeyed/<host>-<user>/ first.
    (lib.mkIf loadAdditionalUserOnlySecrets {
      age.secrets = additionalUserOnlySecrets;
    })

    # Fallback for hosts with age disabled or no master identity.
    # agenix-rekey asserts masterIdentities is non-empty, so provide a dummy at
    # mkDefault priority — real config overrides it whenever present,
    # which means update-masterkeys never sees the placeholder. The
    # paired HM module (modules/hm/age.nix) propagates outerConfig's
    # masterIdentities instead of setting its own dummy, so the merged
    # ageWrapper stays clean.
    #
    # Safety: the `"age"` pubkey is not a valid age recipient (valid
    # recipients start with `age1...`). If this dummy somehow reached a
    # real rekey operation, `age -e -r age` fails loudly with
    # "unknown recipient type: age" — no secret can ever be encrypted
    # to it. Setting this placeholder is therefore safe.
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
