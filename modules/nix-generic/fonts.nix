{ config, lib, pkgs, cfg-meta, ... }:

let
  defaultTerminalFont = "Hack Nerd Font Mono";
  defaultSansSerif = "Noto Sans";
  defaultSerif = "Noto Serif";
  defaultEmoji = "Noto Color Emoji";
  defaultHintingStyle = "slight";
  defaultSubpixelRgba = "rgb";
  defaultSubpixelLcdfilter = "light";
in
{
  options.smind.fonts = {
    nerd = {
      enable = lib.mkEnableOption "Nerd Fonts collection";
    };

    terminal = lib.mkOption {
      type = lib.types.str;
      default = defaultTerminalFont;
      description = "Default terminal font family.";
    };

    defaults = {
      sansSerif = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ defaultSansSerif ];
        description = "Default sans-serif font families.";
      };

      serif = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ defaultSerif ];
        description = "Default serif font families.";
      };

      monospace = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ config.smind.fonts.terminal ];
        description = "Default monospace font families.";
      };

      emoji = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ defaultEmoji ];
        description = "Default emoji font families.";
      };
    };

    fontconfig = {
      antialias = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable font antialiasing.";
      };

      hinting = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable font hinting.";
        };

        style = lib.mkOption {
          type = lib.types.str;
          default = defaultHintingStyle;
          description = "Font hinting style.";
        };
      };

      subpixel = {
        rgba = lib.mkOption {
          type = lib.types.str;
          default = defaultSubpixelRgba;
          description = "Subpixel rendering order.";
        };

        lcdfilter = lib.mkOption {
          type = lib.types.str;
          default = defaultSubpixelLcdfilter;
          description = "Subpixel LCD filter.";
        };
      };
    };
  };

  config = {
    fonts = {
      fontDir.enable = lib.mkIf config.smind.fonts.nerd.enable true;

      packages =
        lib.optionals config.smind.fonts.nerd.enable (with pkgs.nerd-fonts;
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
          ]);
    } // lib.optionalAttrs cfg-meta.isLinux {
      fontconfig = {
        enable = true;

        antialias = config.smind.fonts.fontconfig.antialias;

        hinting = {
          enable = config.smind.fonts.fontconfig.hinting.enable;
          style = config.smind.fonts.fontconfig.hinting.style;
        };

        subpixel = {
          rgba = config.smind.fonts.fontconfig.subpixel.rgba;
          lcdfilter = config.smind.fonts.fontconfig.subpixel.lcdfilter;
        };

        defaultFonts = {
          sansSerif = config.smind.fonts.defaults.sansSerif;
          serif = config.smind.fonts.defaults.serif;
          monospace = config.smind.fonts.defaults.monospace;
          emoji = config.smind.fonts.defaults.emoji;
        };
      };
    };
  };
}
