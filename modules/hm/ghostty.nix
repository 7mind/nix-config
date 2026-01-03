{ config, lib, pkgs, cfg-meta, ... }:

let
  defaultFontSize = if cfg-meta.isDarwin then 14 else 10;
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
  };

  config = lib.mkIf config.smind.hm.ghostty.enable {
    programs.ghostty = {
      enable = true;
      enableZshIntegration = true;

      settings = {
        font-family = "JetBrains Mono";
        font-size = config.smind.hm.ghostty.fontSize;

        window-padding-x = 8;
        window-padding-y = 5;

        scrollback-limit = 10000;

        copy-on-select = "clipboard";
        clipboard-paste-protection = false;

        # Keybindings
        # Copy/Paste (Ctrl+C copies if selection, otherwise sends SIGINT)
        keybind = [
          "ctrl+c=copy_to_clipboard"
          "ctrl+shift+c=text:\\x03"
          "ctrl+v=paste_from_clipboard"
          "ctrl+shift+v=text:\\x16"

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
        ];
      };
    };

    home.packages = [ pkgs.ghostty ];
  };
}
