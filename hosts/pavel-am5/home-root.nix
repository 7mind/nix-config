{ smind-hm, cfg-meta, import_if_exists_or, ... }: {
  imports = smind-hm.imports ++ [
    (import_if_exists_or "${cfg-meta.paths.secrets}/pavel/age-rekey.nix" (import "${cfg-meta.paths.modules}/age-dummy.nix"))
  ];

  age.rekey = {
    masterIdentities = [
      {
        identity = "/does-not-exist";
        pubkey = "age";
      }
    ];
    storageMode = "derivation";
  };

  smind.hm = {
    roles.server = true;
  };
}

