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

        # Skip catppuccin window format — we set our own after the plugin loads.
        set -g @catppuccin_window_status_style "none"

        set -g @catppuccin_status_left_separator " "
        set -g @catppuccin_status_right_separator ""
        set -g @catppuccin_status_connect_separator "no"

        # Load catppuccin (theme colors only, window formats skipped)
        run-shell ${pkgs.tmuxPlugins.catppuccin}/share/tmux-plugins/catppuccin/catppuccin.tmux

        # Remove stale hooks and variables from previous config versions
        set-hook -gu client-resized
        set-hook -gu client-attached
        set -gu @_smind_window_status_format_narrow
        set -gu @_smind_window_status_format_wide
        set -gu @_smind_window_status_current_format_narrow
        set -gu @_smind_window_status_current_format_wide
        set -gu @_smind_window_number_style
        set -gu @_smind_window_text_style
        set -gu @_smind_window_text_suffix
        set -gu @_smind_window_current_number_style
        set -gu @_smind_window_current_text_style
        set -gu @_smind_window_current_text_suffix

        # Window tab format: <space><number><space><dirname:command>
        # -gF resolves theme colors at set time; ## keeps format codes for display time.
        set -gF window-status-format \
          "#[fg=#{@thm_crust},bg=#{@thm_overlay_2}] ##I #[fg=#{@thm_fg},bg=#{@thm_surface_0}]##{b:pane_current_path}:##{pane_current_command} "
        set -gF window-status-current-format \
          "#[fg=#{@thm_crust},bg=#{@thm_mauve}] ##I #[fg=#{@thm_fg},bg=#{@thm_surface_1}]##{b:pane_current_path}:##{pane_current_command} "

        # Status right: user@host:<dirname> when wide, nothing when narrow
        set -gF @_custom_status_right "#[fg=#{@thm_fg},bg=#{@thm_surface_0}] ##(whoami)@##h:##{b:pane_current_path} "
        set -g status-right "#{?#{e|<|:#{client_width},60},,#{E:@_custom_status_right}}"
      '';
    };
  };
}
