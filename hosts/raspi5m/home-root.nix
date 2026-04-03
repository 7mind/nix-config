{ smind-hm, ... }: {
  imports = smind-hm.imports;

  smind.hm = {
    roles.server = true;
  };
}
