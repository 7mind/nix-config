{ config, lib, pkgs, cfg-meta, outerConfig, ... }:

let
  defaultFontSize = if cfg-meta.isDarwin then 14 else 10;
  defaultRows = if cfg-meta.isDarwin then 40 else 60;
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
      default = "7mind";
      description = "Ghostty color theme (use 'ghostty +list-themes' to see available)";
    };

    smind.hm.ghostty.ctrl-keybindings = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Add keybindings also on Ctrl (not just Super)";
    };
  };

  config = lib.mkIf config.smind.hm.ghostty.enable {
    # Custom WCAG-compliant theme
    xdg.configFile."ghostty/themes/7mind".text = ''
      # 7mind
      #
      palette = 0=#000000
      palette = 1=#ee6a6a
      palette = 2=#33aa33
      palette = 3=#cdcd55
      palette = 4=#3333bb
      palette = 5=#bb55bb
      palette = 6=#7acaca
      palette = 7=#cccccc
      palette = 8=#585858
      palette = 9=#ff9999
      palette = 10=#77ff77
      palette = 11=#ffff77
      palette = 12=#aaaaff
      palette = 13=#ff77ff
      palette = 14=#77ffff
      palette = 15=#ffffff

      background = #000000
      foreground = #cccccc

      cursor-color = #ffcc80
      cursor-text = #804d00

      selection-background = #85a3e0
      selection-foreground = #152951
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

        window-decoration = lib.mkIf (outerConfig.smind.desktop.kde.enable or false) "client"; # workaround for https://github.com/ghostty-org/ghostty/discussions/7439 on KDE

        window-width = 160;
        window-height = defaultRows;

        scrollback-limit = 100000000; # ~50k lines at 160 columns (bytes, not lines)

        # Inherit CWD when creating new splits/tabs
        window-inherit-working-directory = true;

        app-notifications = false;

        # TODO: enable when Ghostty 1.3+ is available
        # scrollbar = "system";

        # Don't dim inactive panes
        unfocused-split-opacity = 1;

        copy-on-select = false;
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
      };
    };

    home.packages = lib.mkIf cfg-meta.isLinux [ pkgs.ghostty ];
  };
}
