{ pkgs, config, smind-hm, lib, extended_pkg, cfg-meta, inputs, outerConfig, import_if_exists, import_if_exists_or, ... }:

{
  imports = smind-hm.imports ++ [
    (import_if_exists_or "${cfg-meta.paths.secrets}/pavel/age-rekey.nix" (import "${cfg-meta.paths.modules}/age-dummy.nix"))
    (import_if_exists "${cfg-meta.paths.private}/modules/hm/pavel/cfg-hm.nix")
  ];

  smind.hm = {
    roles.desktop = true;
  };

  programs.direnv = {
    config = {
      whitelist.prefix = [ "~/work" ];
    };
  };

  home.packages = with pkgs; [
  ];
}

