{ config, lib, outerConfig, ... }:

let
  ageEnabled = outerConfig.smind.age.enable;
in
{
  config = lib.mkMerge [
    # Always propagate hostPubkey to suppress agenix-rekey dummy-key warnings
    {
      age.rekey.hostPubkey = outerConfig.age.rekey.hostPubkey;
    }

    # Copy rekey config from outer config when age is enabled
    (lib.mkIf ageEnabled {
      age.rekey = {
        masterIdentities = outerConfig.age.rekey.masterIdentities;
        storageMode = outerConfig.age.rekey.storageMode;
        localStorageDir = outerConfig.age.rekey.localStorageDir;
      };
    })

    # Fallback for HM configs with age disabled.
    # Empty masterIdentities so disabled users don't inject an invalid
    # dummy pubkey into the merged ageWrapper (breaks update-masterkeys).
    (lib.mkIf (!ageEnabled) {
      age.rekey = {
        masterIdentities = [];
        storageMode = "derivation";
      };
    })
  ];
}
