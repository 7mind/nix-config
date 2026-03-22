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
        set -g @catppuccin_window_number_position "right"

        set -g @catppuccin_window_left_separator ""
        set -g @catppuccin_window_right_separator " "
        set -g @catppuccin_window_middle_separator " █"

        # Compact: show window index when narrow, name when wide
        set -g @catppuccin_window_text "#{?#{e|<|:#{client_width},80},#I,#W}"
        set -g @catppuccin_window_current_text "#{?#{e|<|:#{client_width},80},#I,#W}"

        set -g @catppuccin_status_left_separator " "
        set -g @catppuccin_status_right_separator ""
        set -g @catppuccin_status_connect_separator "no"

        set -g @catppuccin_directory_text " #{pane_current_path}"

        # Load catppuccin after options are set
        run-shell ${pkgs.tmuxPlugins.catppuccin}/share/tmux-plugins/catppuccin/catppuccin.tmux

        # Compact: hide status modules when narrow
        set -g status-right "#{?#{e|<|:#{client_width},80},,#{E:@catppuccin_status_directory}#{E:@catppuccin_status_user}#{E:@catppuccin_status_host}#{E:@catppuccin_status_session}}"
      '';
    };
  };
}
