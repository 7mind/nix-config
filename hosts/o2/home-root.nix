{ smind-hm, cfg-meta, ... }: {
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.secrets}/pavel/age-rekey.nix"
  ];

  smind.hm = {
    roles.server = true;
  };
}

