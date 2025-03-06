{ cfg-meta, ... }:

{
  age.rekey.storageMode = "local";
  age.rekey.localStorageDir = cfg-meta.paths.secrets + "/rekeyed/${cfg-meta.hostname}";
}
