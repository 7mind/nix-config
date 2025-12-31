{ smind-hm, cfg-meta, import_if_exists_or, ... }: {
  imports = smind-hm.imports ++ [
    # Skip age-rekey for now until secrets are set up for this host
    "${cfg-meta.paths.modules}/age-dummy.nix"
  ];

  smind.hm = {
    roles.server = true;
  };
}
