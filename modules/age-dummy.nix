{ lib, config, ... }:

{
  config = lib.mkIf (!config.smind.age.enable) {
    age.rekey = {
      masterIdentities = [
        {
          identity = "/does-not-exist";
          pubkey = "age";
        }
      ];
      storageMode = "derivation";
    };
  };
}
