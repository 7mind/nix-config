{ config, lib, pkgs, cfg-meta, outerConfig, ... }:

let
  defaultFontSize = if cfg-meta.isDarwin then 14 else 10;
  defaultRows = if config.smind.hm.ghostty.small-window then 40 else 60;
  defaultWidth = if config.smind.hm.ghostty.small-window then 120 else 160;
in
{
  options = {
    smind.hm.ghostty.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Ghostty terminal emulator";
    };

    smind.hm.ghostty.fontSize = lib.mkOption {
      type = lib.types.int;
      default = defaultFontSize;
      description = "Ghostty font size";
    };

    smind.hm.ghostty.theme = lib.mkOption {
      type = lib.types.str;
      default = "7mind-balanced";
      description = "Ghostty color theme (use 'ghostty +list-themes' to see available)";
    };

    smind.hm.ghostty.ctrl-keybindings = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Add keybindings also on Ctrl (not just Super)";
    };

    smind.hm.ghostty.small-window = lib.mkOption {
      type = lib.types.bool;
      default = cfg-meta.isDarwin;
      description = "Spawn a smaller window by default";
    };

    smind.hm.ghostty.copy-on-select = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Automatically copy selected text to clipboard";
    };
  };

  config = lib.mkIf config.smind.hm.ghostty.enable {
    # Custom WCAG-compliant theme
    xdg.configFile."ghostty/themes/7mind".text = ''
      # 7mind
      #
      palette = 0=#000000
      palette = 1=#fe5b0e
      palette = 2=#00a77d
      palette = 3=#b4f700
      palette = 4=#005ed1
      palette = 5=#d859fe
      palette = 6=#00d0e6
      palette = 7=#cecdcd
      palette = 8=#555555
      palette = 9=#ffbd92
      palette = 10=#4dffd2
      palette = 11=#f9ffbc
      palette = 12=#92d7ff
      palette = 13=#dcceff
      palette = 14=#68fefe
      palette = 15=#ffffff

      background = #000000
      foreground = #cecdcd

      cursor-color = #ffcc80
      cursor-text = #804d00

      selection-background = #5276bf
      selection-foreground = #0f2247
    '';
    xdg.configFile."ghostty/themes/7mind+".text = ''
      # 7mind+
      #
      palette = 0=#000000
      palette = 1=#fe5b0e
      palette = 2=#19ab00
      palette = 3=#b4b400
      palette = 4=#0d73cc
      palette = 5=#d859fe
      palette = 6=#00d0e6
      palette = 7=#cecdcd
      palette = 8=#555555
      palette = 9=#ffbd92
      palette = 10=#4dffd2
      palette = 11=#f9ffbc
      palette = 12=#92d7ff
      palette = 13=#dcceff
      palette = 14=#68fefe
      palette = 15=#ffffff

      background = #000000
      foreground = #cecdcd

      cursor-color = #ffcc80
      cursor-text = #804d00

      selection-background = #5276bf
      selection-foreground = #0f2247
    '';
    xdg.configFile."ghostty/themes/7mind-balanced".text = ''
      # 7mind-balanced
      #
      palette = 0=#000000
      palette = 1=#fea095
      palette = 2=#00aa4b
      palette = 3=#e1b400
      palette = 4=#688eff
      palette = 5=#fe90fe
      palette = 6=#00cbe1
      palette = 7=#dcdcdc
      palette = 8=#808080
      palette = 9=#fed1d7
      palette = 10=#bee994
      palette = 11=#ffd885
      palette = 12=#d9d9fe
      palette = 13=#ffcdfe
      palette = 14=#98e8fe
      palette = 15=#ffffff

      background = #000000
      foreground = #dcdcdc

      cursor-color = #ffcc80
      cursor-text = #804d00

      selection-background = #5276bf
      selection-foreground = #0f2247
    '';



    # Default Kitty theme
    xdg.configFile."ghostty/themes/kitty".text = ''
      # kitty default
      #
      palette = 0=#000000
      palette = 1=#cc0403
      palette = 2=#19cb00
      palette = 3=#cecb00
      palette = 4=#0d73cc
      palette = 5=#cb1ed1
      palette = 6=#0dcdcd
      palette = 7=#dddddd
      palette = 8=#767676
      palette = 9=#f2201f
      palette = 10=#23fd00
      palette = 11=#fffd00
      palette = 12=#1a8fff
      palette = 13=#fd28ff
      palette = 14=#14ffff
      palette = 15=#ffffff

      background = #000000
      foreground = #dddddd

      cursor-color = #cccccc
      cursor-text = #111111

      selection-background = #5276bf
      selection-foreground = #0f2247
    '';



    # Set as default terminal via xdg-terminal-exec (modern GNOME)
    # See: https://gitlab.freedesktop.org/terminal-wg/specifications
    xdg.configFile."xdg-terminals.list".text = ''
      com.mitchellh.ghostty.desktop
    '';

    xdg.mimeApps.defaultApplications = lib.mkIf cfg-meta.isLinux {
      "x-scheme-handler/terminal" = "com.mitchellh.ghostty.desktop";
    };

    programs.ghostty = {
      enable = true;
      package = lib.mkIf cfg-meta.isDarwin null; # On macOS, Ghostty is installed via Homebrew/DMG
      enableZshIntegration = true;

      settings = {
        theme = config.smind.hm.ghostty.theme;
        font-family = "JetBrains Mono";
        font-size = config.smind.hm.ghostty.fontSize;

        window-padding-x = 8;
        window-padding-y = 5;

        window-width = defaultWidth;
        window-height = defaultRows;

        scrollback-limit = 100000000; # ~50k lines at 160 columns (bytes, not lines)

        # Inherit CWD when creating new splits/tabs
        window-inherit-working-directory = true;

        app-notifications = false;

        # TODO: enable when Ghostty 1.3+ is available
        # scrollbar = "system";

        # Don't dim inactive panes
        unfocused-split-opacity = 1;

        copy-on-select = config.smind.hm.ghostty.copy-on-select;
        selection-clear-on-copy = true;
        clipboard-paste-protection = false;

        # Always use block cursor, ignore app requests to change it
        cursor-style = "block";
        cursor-style-blink = false;

        keybind = [
          "clear"

          # Copy/Paste - performable: only triggers if there's a selection, otherwise passes through
          "performable:super+c=copy_to_clipboard"
          "super+v=paste_from_clipboard"

          # Clear screen and scrollback
          "super+k=clear_screen"

          # Splits
          "super+d=new_split:down"
          "super+shift+d=new_split:right"

          # Navigate panes
          "super+up=goto_split:top"
          "super+down=goto_split:bottom"
          "super+left=goto_split:left"
          "super+right=goto_split:right"

          # Resize panes
          "super+shift+up=resize_split:up,10"
          "super+shift+down=resize_split:down,10"
          "super+shift+left=resize_split:left,10"
          "super+shift+right=resize_split:right,10"

          # Tabs (both super and ctrl for kanata compatibility)
          "super+t=new_tab"
          "super+bracket_left=previous_tab"
          "super+bracket_right=next_tab"

          "super+n=new_window"
          "super+w=close_surface"

          # Scrolling
          "shift+page_up=scroll_page_fractional:-0.5"
          "shift+page_down=scroll_page_fractional:0.5"

          # Essential defaults to keep
          "super+shift+comma=reload_config"
          "super+plus=increase_font_size:1"
          "super+minus=decrease_font_size:1"
          "super+zero=reset_font_size"
        ] ++ lib.optionals config.smind.hm.ghostty.ctrl-keybindings [
          # Additional Ctrl keybindings (in addition to Super)
          "performable:ctrl+c=copy_to_clipboard"
          "ctrl+v=paste_from_clipboard"
          "ctrl+t=new_tab"
          "ctrl+n=new_window"
          "ctrl+w=close_surface"
          "ctrl+shift+comma=reload_config"
          "ctrl+plus=increase_font_size:1"
          "ctrl+minus=decrease_font_size:1"
          "ctrl+zero=reset_font_size"
        ];
      } // lib.optionalAttrs cfg-meta.isLinux {
        window-decoration = lib.mkIf (outerConfig.smind.desktop.kde.enable or false) "client"; # workaround for https://github.com/ghostty-org/ghostty/discussions/7439 on KDE
      };
    };

    home.packages = lib.mkIf cfg-meta.isLinux [ pkgs.ghostty ];
  };
}
