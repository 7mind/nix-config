{ pkgs, smind-hm, ... }:

{
  imports = smind-hm.imports;

  smind.hm = {
    roles.desktop = true;
    firefox.sync-username = "pshirshov@gmail.com";
    autostart.programs = with pkgs; [
      {
        name = "element";
        exec = "${element-desktop}/bin/element-desktop --hidden";
      }
      {
        name = "slack";
        exec = "${slack}/bin/slack -u";
      }
      {
        name = "telegram-desktop";
        exec = "${pkgs.telegram-desktop}/bin/telegram-desktop -startintray";
      }
    ];
  };

  programs.direnv = {
    config = {
      whitelist.prefix = [ "~/work" ];
    };
  };

  home.packages = with pkgs; [
    element-desktop
    bitwarden-desktop

    jetbrains.idea-ultimate
    visualvm

    vlc
    telegram-desktop

    pstree
    pciutils
  ];

}

