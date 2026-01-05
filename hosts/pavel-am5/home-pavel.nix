{ pkgs, config, smind-hm, lib, extended_pkg, cfg-meta, xdg_associate, outerConfig, import_if_exists, import_if_exists_or, ... }:

{
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic.nix"
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic-linux.nix"
  ];

}

