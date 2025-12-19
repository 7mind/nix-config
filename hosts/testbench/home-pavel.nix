{ pkgs, smind-hm, cfg-meta, ... }:

{
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic.nix"
  ];


  smind.hm = {
    roles.server = true;
  };

  programs.direnv = {
    config = {
      whitelist.prefix = [ "~/work" ];
    };
  };

  home.packages = with pkgs; [
  ];

}

