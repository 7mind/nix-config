{ pkgs, config, smind-hm, lib, cfg-meta, import_if_exists_or, ... }:

{
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic.nix"
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic-linux.nix"
  ];

  smind.hm = {
    roles.desktop = true;
    wezterm.fontSize = 11;
    vscodium.fontSize = 14;

    autostart.programs = with pkgs; [
      {
        name = "element-main";
        exec = "${element-desktop}/bin/element-desktop --hidden";
      }
      # {
      #   name = "element-2nd";
      #   exec = "${element-desktop}/bin/element-desktop --hidden --profile secondary";
      # }
      {
        name = "slack";
        exec = "${slack}/bin/slack -u";
      }
    ];
  };
}
