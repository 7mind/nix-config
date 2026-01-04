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
    ghostty.enable = true;
    ghostty.fontSize = 11;

    # Resource-limited Electron apps
    electron-wrappers = {
      enable = true;
      cpuQuota = "100%";
      cpuWeight = 50;
      memoryMax = "4G";
      slack.enable = true;
      element.enable = true;
    };

    autostart.programs = [
      {
        name = "element-main";
        exec = "${config.home.profileDirectory}/bin/element-desktop";
      }
      {
        name = "slack";
        exec = "${config.home.profileDirectory}/bin/slack";
      }
    ];
  };
}
