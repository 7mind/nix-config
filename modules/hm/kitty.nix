{ config, lib, ... }:

{
  options = {
    smind.hm.kitty.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Kitty terminal with custom keybindings";
    };
  };

  config = lib.mkIf config.smind.hm.kitty.enable {
    programs.kitty = {
      enable = true;
      font = {
        name = "Hack Nerd Font Mono";
        size = 10;
      };
      settings = {
        disable_ligatures = "always";
        scrollback_lines = 20000;
        copy_on_select = true;
        strip_trailing_spaces = "always";
        tab_bar_edge = "top";
        tab_bar_style = "slant";
        tab_bar_min_tabs = 1;
        tab_activity_symbol = "*";
        active_tab_foreground = "#eeeeee";
        active_tab_background = "#406040";
        inactive_tab_foreground = "#bbbbbb";
        inactive_tab_background = "#404040";
        kitty_mod = "cmd";
        clear_all_shortcuts = "yes";
        enabled_layouts = "splits:split_axis=horizontal";
        scrollback_pager_history_size = "512";
      };

      keybindings = {

        #"ctrl+s" = "paste_from_selection";
        # "ctrl+t" = "new_tab";
        # "ctrl+w" = "close_tab";
        # "ctrl+q" = "close_os_window";

        "kitty_mod+d" = "launch --location=hsplit";
        "kitty_mod+shift+d" = "launch --location=vsplit";

        "kitty_mod+n" = "new_os_window";
        "kitty_mod+]" = "next_window";
        "kitty_mod+[" = "previous_window";

        "ctrl+c" = "copy_and_clear_or_interrupt";
        "ctrl+v" = "paste_from_clipboard";
        "ctrl+shift+v" = "paste_from_clipboard";
        "ctrl+shift+c" = "copy_to_clipboard";
        "kitty_mod+c" = "copy_to_clipboard";
        "kitty_mod+v" = "paste_from_clipboard";

        #"kitty_mod+s" = "paste_from_selection";
        "kitty_mod+t" = "new_tab";
        "kitty_mod+w" = "close_tab";
        "kitty_mod+q" = "close_os_window";
        "kitty_mod+s" = "start_resizing_window";

        "kitty_mod+up" = "scroll_line_up";
        "kitty_mod+down" = "scroll_line_down";
        "kitty_mod+page_up" = "scroll_page_up";
        "kitty_mod+page_down" = "scroll_page_down";
        "kitty_mod+home" = "scroll_home";
        "kitty_mod+end" = "scroll_end";
        "kitty_mod+h" = "show_scrollback";

        "kitty_mod+f" = "move_window_forward";
        "kitty_mod+b" = "move_window_backward";
        "kitty_mod+`" = "move_window_to_top";
        "kitty_mod+1" = "first_window";
        "kitty_mod+2" = "second_window";
        "kitty_mod+3" = "third_window";
        "kitty_mod+4" = "fourth_window";
        "kitty_mod+5" = "fifth_window";
        "kitty_mod+6" = "sixth_window";
        "kitty_mod+7" = "seventh_window";
        "kitty_mod+8" = "eighth_window";
        "kitty_mod+9" = "ninth_window";
        "kitty_mod+0" = "tenth_window";
        "kitty_mod+right" = "next_tab";
        "kitty_mod+left" = "previous_tab";

        "kitty_mod+l" = "next_layout";
        "kitty_mod+u" = "open_url_with_hints";
        "kitty_mod+p>f" = "kitten hints --type path --program -";
        "kitty_mod+p>shift+f" = "kitten hints --type path";
        "kitty_mod+p>l" = "kitten hints --type line --program -";
        "kitty_mod+p>w" = "kitten hints --type word --program -";
        "kitty_mod+p>h" = "kitten hints --type hash --program -";
        "kitty_mod+p>n" = "kitten hints --type linenum";
        "kitty_mod+p>y" = "kitten hints --type hyperlink";
        "kitty_mod+escape" = "kitty_shell window";
        "kitty_mod+shift+k" = "clear_terminal reset active";
        "kitty_mod+f5" = "load_config_file";
        "kitty_mod+f6" = "debug_config";
      };
    };
  };
}
