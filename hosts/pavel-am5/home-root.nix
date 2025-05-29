{ smind-hm, cfg-meta, import_if_exists, ... }: {
  imports = smind-hm.imports ++ [
    (import_if_exists "${cfg-meta.paths.secrets}/pavel/age-rekey.nix")
  ];

  age.rekey = {
    masterIdentities = [
      {
        identity = "/does-not-exist";
        pubkey = "age";
      }
    ];
  };

  smind.hm = {
    roles.server = true;
  };
}

