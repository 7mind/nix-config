{ config, lib, cfg-meta, ... }:

let
  host = config.smind.hm.globals;
  ageEnabled = host.age.enable;
in
if cfg-meta.isStandalone or false then {
  age.enable = lib.mkDefault false;
  age.rekey = {
    # agenix-rekey requires an identity even without secrets; reuse the
    # invalid placeholder from disabled system configurations.
    masterIdentities = lib.mkDefault [
      { identity = "/does-not-exist"; pubkey = "age"; }
    ];
    storageMode = lib.mkDefault "derivation";
    # See modules/nix-generic/age.nix: keep the merged rekey apps arch-neutral.
    agePlugins = lib.mkDefault [ ];
  };
} else {
  config = lib.mkMerge [
    # Always propagate hostPubkey and masterIdentities from the host projection.
    # hostPubkey suppresses agenix-rekey dummy-key warnings; real
    # masterIdentities satisfy agenix-rekey's non-empty assertion without
    # polluting the merged ageWrapper used by update-masterkeys.
    {
      age.rekey = lib.mkMerge [
        (lib.mkIf (host.age.hostPubkey != null) {
          hostPubkey = host.age.hostPubkey;
        })
        { masterIdentities = host.age.masterIdentities; }
        # See modules/nix-generic/age.nix: keep the merged rekey apps arch-neutral.
        { agePlugins = lib.mkDefault [ ]; }
      ];
    }

    (lib.mkIf (ageEnabled && host.age.storageMode != null) {
      age.rekey = {
        storageMode = host.age.storageMode;
        localStorageDir = host.age.localStorageDir;
      };
    })

    (lib.mkIf (!ageEnabled) {
      age.rekey.storageMode = "derivation";
    })
  ];
}
