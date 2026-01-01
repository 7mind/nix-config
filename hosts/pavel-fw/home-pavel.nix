{ pkgs, config, smind-hm, lib, cfg-meta, import_if_exists_or, ... }:

{
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic.nix"
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic-linux.nix"
  ];

  smind.hm = {
    roles.desktop = true;

    autostart.programs = with pkgs; [

    ];
  };
}
