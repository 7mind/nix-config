{ smind-hm, cfg-meta, import_if_exists, ... }: {
  imports = smind-hm.imports ++ [
    (import_if_exists "${cfg-meta.paths.secrets}/pavel/age-rekey.nix")
  ];

  smind.hm = {
    roles.server = true;
  };
}

