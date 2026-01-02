{ smind-hm, cfg-meta, import_if_exists_or, ... }: {
  imports = smind-hm.imports ++ [
    (import_if_exists_or "${cfg-meta.paths.secrets}/pavel/age-rekey.nix" (import "${cfg-meta.paths.modules}/age-dummy.nix"))
  ];

  smind.hm = {
    roles.server = true;
  };
}
