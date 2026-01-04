{ config, lib, pkgs, cfg-meta, ... }:

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
      default = "GitHub Dark";
      description = "Ghostty color theme (use 'ghostty +list-themes' to see available)";
    };
  };

  config = lib.mkIf config.smind.hm.ghostty.enable {
    # Set as default terminal in GNOME
    dconf.settings = lib.mkIf cfg-meta.isLinux {
      "org/gnome/desktop/applications/terminal" = {
        exec = "ghostty";
        exec-arg = "-e";
      };
    };

    xdg.mimeApps.defaultApplications = lib.mkIf cfg-meta.isLinux {
      "x-scheme-handler/terminal" = "com.mitchellh.ghostty.desktop";
    };

    programs.ghostty = {
      enable = true;
      enableZshIntegration = true;

      settings = {
        theme = config.smind.hm.ghostty.theme;
        font-family = "JetBrains Mono";
        font-size = config.smind.hm.ghostty.fontSize;

        window-padding-x = 8;
        window-padding-y = 5;

        window-width = 160;
        window-height = defaultRows;

        scrollback-limit = 10000;

        app-notifications = false;

        # TODO: enable when Ghostty 1.3+ is available
        # scrollbar = "system";

        # Don't dim inactive panes
        unfocused-split-opacity = 1;

        copy-on-select = false;
        selection-clear-on-copy = true;
        clipboard-paste-protection = false;

        # Clear all default keybindings and define our own
        keybind = [
          "clear"

          # Copy/Paste - performable: only triggers if there's a selection, otherwise passes through
          "performable:ctrl+c=copy_to_clipboard"
          "performable:super+c=copy_to_clipboard"
          "ctrl+v=paste_from_clipboard"
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

          # Tabs
          "super+t=new_tab"
          "ctrl+t=new_tab"
          "super+bracket_left=previous_tab"
          "super+bracket_right=next_tab"

          # Window
          "super+n=new_window"
          "ctrl+n=new_window"
          "super+w=close_surface"
          "ctrl+w=close_surface"

          # Scrolling
          "shift+page_up=scroll_page_fractional:-0.5"
          "shift+page_down=scroll_page_fractional:0.5"

          # Essential defaults to keep
          "ctrl+shift+comma=reload_config"
          "ctrl+plus=increase_font_size:1"
          "ctrl+minus=decrease_font_size:1"
          "ctrl+zero=reset_font_size"
        ];
      };
    };

    home.packages = [ pkgs.ghostty ];
  };
}
