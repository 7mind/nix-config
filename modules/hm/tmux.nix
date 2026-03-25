{ config, lib, pkgs, ... }:

{
  options = {
    smind.hm.tmux.enable = lib.mkEnableOption "tmux with custom configuration";
  };

  config = lib.mkIf config.smind.hm.tmux.enable {
    programs.tmux = {
      enable = true;
      clock24 = true;
      aggressiveResize = true;
      plugins = with pkgs; [ tmuxPlugins.yank ];

      extraConfig = ''
        # Mouse works as expected, incl. scrolling
        set-option -g mouse on

        # Prefer tmux's own terminfo (more accurate capabilities than screen-256color)
        set -g default-terminal "tmux-256color"

        # Truecolor: GNOME Terminal (VTE) typically reports TERM=xterm-256color
        set -as terminal-features ",xterm*:RGB"

        # Catppuccin options — must be set BEFORE plugin loads (v2.1.3 API).
        # Use "custom" style so catppuccin doesn't override our separators.
        set -g @catppuccin_window_status_style "custom"
        set -g @catppuccin_window_number_position "left"

        set -g @catppuccin_window_left_separator " "
        set -g @catppuccin_window_right_separator ""
        set -g @catppuccin_window_middle_separator " "

        # Tab text: directory_name:command_name
        set -g @catppuccin_window_text "#{b:pane_current_path}:#{pane_current_command}"
        set -g @catppuccin_window_current_text "#{b:pane_current_path}:#{pane_current_command}"

        set -g @catppuccin_status_left_separator " "
        set -g @catppuccin_status_right_separator ""
        set -g @catppuccin_status_connect_separator "no"

        # Load catppuccin after options are set
        run-shell ${pkgs.tmuxPlugins.catppuccin}/share/tmux-plugins/catppuccin/catppuccin.tmux

        # Store status-right content in a variable so commas in #[fg=,bg=]
        # don't get parsed as #{?cond,true,false} delimiters.
        # Use -gF to resolve theme colors now; ## escapes keep dynamic parts for display time.
        set -gF @_custom_status_right "#[fg=#{@thm_fg},bg=#{@thm_surface_0}] ##(whoami)@##h:##{b:pane_current_path} "

        # Wide: user@host:<dirname>, Narrow: nothing
        set -g status-right "#{?#{e|<|:#{client_width},80},,#{E:@_custom_status_right}}"
      '';
    };
  };
}
