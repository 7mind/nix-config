{ lib, config, ... }:

{
  options =
    {
      smind.with-private = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "";
      };
    };



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
