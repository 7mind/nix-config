{ ... }:

{
  age.rekey = {
    masterIdentities = [
      {
        identity = "/does-not-exist";
        pubkey = "age";
      }
    ];
    storageMode = "derivation";
  };
}
