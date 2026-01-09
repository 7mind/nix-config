{ config, lib, outerConfig, ... }:

let
  ageEnabled = outerConfig.smind.age.enable;
in
{
  config = lib.mkMerge [
    # Copy rekey config from outer config when age is enabled
    (lib.mkIf ageEnabled {
      age.rekey = {
        hostPubkey = outerConfig.age.rekey.hostPubkey;
        masterIdentities = outerConfig.age.rekey.masterIdentities;
        storageMode = outerConfig.age.rekey.storageMode;
        localStorageDir = outerConfig.age.rekey.localStorageDir;
      };
    })

    # Dummy config when age is disabled
    (lib.mkIf (!ageEnabled) {
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
