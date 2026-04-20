{ config, lib, outerConfig, ... }:

let
  ageEnabled = outerConfig.smind.age.enable;
in
{
  config = lib.mkMerge [
    # Always propagate hostPubkey and masterIdentities from the outer (system)
    # config. hostPubkey suppresses agenix-rekey dummy-key warnings; real
    # masterIdentities satisfy agenix-rekey's non-empty assertion without
    # polluting the merged ageWrapper used by update-masterkeys.
    {
      age.rekey = {
        hostPubkey = outerConfig.age.rekey.hostPubkey;
        masterIdentities = outerConfig.age.rekey.masterIdentities;
      };
    }

    (lib.mkIf ageEnabled {
      age.rekey = {
        storageMode = outerConfig.age.rekey.storageMode;
        localStorageDir = outerConfig.age.rekey.localStorageDir;
      };
    })

    (lib.mkIf (!ageEnabled) {
      age.rekey.storageMode = "derivation";
    })
  ];
}
