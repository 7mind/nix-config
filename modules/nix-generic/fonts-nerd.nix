{ config, lib, pkgs, cfg-meta, ... }:

{
  options = {
    smind.fonts.nerd.enable = lib.mkEnableOption "Nerd Fonts collection";
  };

  config = {
    fonts = lib.mkIf config.smind.fonts.nerd.enable
      {
        fontDir.enable = true;
        packages = with pkgs.nerd-fonts;
          [
            droid-sans-mono
            fira-code
            hack
            iosevka
            fira-mono
            jetbrains-mono
            roboto-mono
            inconsolata
            meslo-lg
            ubuntu-mono
            dejavu-sans-mono
          ];

      } // (if cfg-meta.isLinux then {
      fontconfig = {
        enable = true;
        antialias = true;
        subpixel.rgba = "rgb";
        subpixel.lcdfilter = "light";
        hinting.style = "slight";
        hinting.enable = true;
        defaultFonts.sansSerif = [ "Noto Sans" ];
        defaultFonts.serif = [ "Noto Serif" ];
        defaultFonts.monospace = [ "Hack Nerd Font Mono" ];
        defaultFonts.emoji = [ "Noto Color Emoji" ];
      };

    } else { });
  };
}
