{ config, lib, cfg-meta, ... }:

let
  host = config.smind.hm.fromHost;
  ageEnabled = host.age.enable;
in
if cfg-meta.isStandalone or false then { } else {
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
