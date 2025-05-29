{ lib, config, ... }:

{
  config = lib.mkIf (!config.smind.with-private) {
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
