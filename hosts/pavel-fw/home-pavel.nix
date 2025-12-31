{ pkgs, config, smind-hm, lib, cfg-meta, import_if_exists_or, ... }:

{
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic.nix"
  ];

  smind.hm = {
    roles.desktop = true;

    autostart.programs = with pkgs; [
      {
        name = "bitwarden";
        exec = "${bitwarden-desktop}/bin/bitwarden";
      }
    ];
  };

  programs.direnv = {
    config = {
      whitelist.prefix = [ "~/work" ];
    };
  };

  home.pointerCursor = {
    gtk.enable = true;
    x11.enable = true;
    package = pkgs.adwaita-icon-theme;
    name = "Adwaita";
    size = 32;
  };

  home.packages = with pkgs; [
    bitwarden-desktop
    vlc
  ];
}
