{ config, lib, pkgs, ... }:

let
  usageConfig = module: pkgs.writeText "tmux-${lib.toLower module.type}.json" (builtins.toJSON {
    logo.type = "none";
    display = {
      pipe = true;
      showErrors = true;
      key.type = "none";
      percent = {
        type = 1;
        ndigits = 0;
        width = 2;
      };
    };
    modules = [ module ];
  });
  cpuUsageConfig = usageConfig {
    type = "CPUUsage";
    format = "{avg}";
    waitTime = 1000;
  };
  memoryUsageConfig = usageConfig {
    type = "Memory";
    format = "{percentage}";
  };
  networkTrafficConfig = usageConfig {
    type = "NetIO";
    format = "{rx-bytes} {tx-bytes}";
    defaultRouteOnly = true;
    waitTime = 1000;
  };
  networkTraffic = pkgs.writeShellApplication {
    name = "tmux-network-traffic";
    runtimeInputs = [ pkgs.fastfetch-minimal pkgs.gawk ];
    text = ''
      export LC_ALL=C
      fastfetch --config ${networkTrafficConfig} | awk '{ printf "↓%7.2f ↑%7.2f", $1 / (1024 * 1024), $2 / (1024 * 1024) }'
    '';
  };
  toggleHtop = pkgs.writeShellApplication {
    name = "tmux-toggle-htop";
    runtimeInputs = [ pkgs.tmux pkgs.htop ];
    text = ''
      session_id="$(tmux display-message -p '#{session_id}')"
      window_id="$(tmux show-options -qv -t "$session_id" @smind_htop_window)"
      existing_window_id=""
      if [[ -n "$window_id" ]]; then
        existing_window_id="$(tmux list-windows -t "$session_id" -f "#{==:#{window_id},$window_id}" -F '#{window_id}')"
      fi

      if [[ "$existing_window_id" == "$window_id" ]] && [[ -n "$window_id" ]]; then
        tmux kill-window -t "$window_id"
        tmux set-option -qu -t "$session_id" @smind_htop_window
      else
        tmux set-option -qu -t "$session_id" @smind_htop_window
        window_id="$(tmux new-window -P -F '#{window_id}' -t "$session_id:" -n htop htop)"
        tmux set-option -q -t "$session_id" @smind_htop_window "$window_id"
      fi
    '';
  };
  toggleBandwhich = pkgs.writeShellApplication {
    name = "tmux-toggle-bandwhich";
    runtimeInputs = [ pkgs.tmux ];
    text = ''
      session_id="$(tmux display-message -p '#{session_id}')"
      window_id="$(tmux show-options -qv -t "$session_id" @smind_bandwhich_window)"
      existing_window_id=""
      if [[ -n "$window_id" ]]; then
        existing_window_id="$(tmux list-windows -t "$session_id" -f "#{==:#{window_id},$window_id}" -F '#{window_id}')"
      fi

      if [[ "$existing_window_id" == "$window_id" ]] && [[ -n "$window_id" ]]; then
        tmux kill-window -t "$window_id"
        tmux set-option -qu -t "$session_id" @smind_bandwhich_window
      else
        tmux set-option -qu -t "$session_id" @smind_bandwhich_window
        window_id="$(tmux new-window -P -F '#{window_id}' -t "$session_id:" -n bandwhich bandwhich)"
        tmux set-option -q -t "$session_id" @smind_bandwhich_window "$window_id"
      fi
    '';
  };
in
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
        set-option -g mouse on
        set -g renumber-windows on

        # Forward OSC 52 clipboard writes to the outer terminal (no general passthrough).
        set -g set-clipboard on

        bind c new-window -c "#{pane_current_path}"
        bind '"' split-window -v -c "#{pane_current_path}"
        bind % split-window -h -c "#{pane_current_path}"

        # Prefer tmux's own terminfo (more accurate capabilities than screen-256color)
        set -g default-terminal "tmux-256color"

        # Truecolor: GNOME Terminal (VTE) typically reports TERM=xterm-256color
        set -as terminal-features ",xterm*:RGB:sync"

        # Extended (CSI u / "fixterms") keys: let applications distinguish
        # modified keys that legacy terminals collapse — Shift+Enter / Ctrl+Enter
        # vs plain Enter, Ctrl+I vs Tab, etc. Needed by agent TUIs (e.g. pi,
        # which uses Shift+Enter for a newline vs Enter to send). `on` forwards
        # them to apps that request the mode; :extkeys advertises the capability
        # upstream. The outer terminal must also support it (ghostty/kitty/
        # wezterm do).
        set -g extended-keys on
        set -as terminal-features ",xterm*:extkeys"
        set -g extended-keys-format csi-u

        # Skip catppuccin window format — we set our own after the plugin loads.
        set -g @catppuccin_window_status_style "none"

        set -g @catppuccin_status_left_separator " "
        set -g @catppuccin_status_right_separator ""
        set -g @catppuccin_status_connect_separator "no"

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

        # Window tab format variants (## escapes keep format codes for display time).
        # rename-window disables automatic-rename on that window; treat that as a
        # user-set name and show it instead of path:command.
        set -gF @_smind_wfmt_wide \
          "#[fg=#{@thm_crust},bg=#{@thm_overlay_2}] ##I #[fg=#{@thm_fg},bg=#{@thm_surface_0}]##{?automatic-rename,##{b:pane_current_path}:##{pane_current_command},##{window_name}} "
        set -gF @_smind_wfmt_narrow \
          "#[fg=#{@thm_crust},bg=#{@thm_overlay_2}] ##I "
        set -gF @_smind_cfmt_wide \
          "#[fg=#{@thm_crust},bg=#{@thm_mauve}] ##I #[fg=#{@thm_fg},bg=#{@thm_surface_1}]##{?automatic-rename,##{b:pane_current_path}:##{pane_current_command},##{window_name}} "
        set -gF @_smind_cfmt_narrow \
          "#[fg=#{@thm_crust},bg=#{@thm_mauve}] ##I "

        set -gF window-status-format "#{@_smind_wfmt_wide}"
        set -gF window-status-current-format "#{@_smind_cfmt_wide}"

        # Switch between wide/narrow on resize (#{@var} avoids re-expanding #I)
        set-hook -g client-resized[0] \
          'if-shell -F "#{e|<|:#{client_width},80}" \
            "set -Fg window-status-format \"#{@_smind_wfmt_narrow}\" ; set -Fg window-status-current-format \"#{@_smind_cfmt_narrow}\"" \
            "set -Fg window-status-format \"#{@_smind_wfmt_wide}\" ; set -Fg window-status-current-format \"#{@_smind_cfmt_wide}\""'
        set-hook -g client-attached[0] \
          'if-shell -F "#{e|<|:#{client_width},80}" \
            "set -Fg window-status-format \"#{@_smind_wfmt_narrow}\" ; set -Fg window-status-current-format \"#{@_smind_cfmt_narrow}\"" \
            "set -Fg window-status-format \"#{@_smind_wfmt_wide}\" ; set -Fg window-status-current-format \"#{@_smind_cfmt_wide}\""'

        # Status right: user@host and CPU/memory utilization when wide, nothing when narrow
        set -g status-interval 5
        set -g status-right-length 100
        bind-key -n MouseDown1Control0 run-shell ${lib.getExe toggleHtop}
        bind-key -n MouseDown1Control1 run-shell ${lib.getExe toggleBandwhich}
        set -gF @_custom_status_right "#[fg=#{@thm_fg},bg=#{@thm_surface_0}] ##(whoami)@##h | #[range=control|0] ##(${lib.getExe pkgs.fastfetch-minimal} --config ${cpuUsageConfig})#[norange] | #[range=control|0] ##(${lib.getExe pkgs.fastfetch-minimal} --config ${memoryUsageConfig})#[norange] | #[range=control|1]󰾆 ##(${lib.getExe networkTraffic})#[norange] "
        set -g status-right "#{?#{e|<|:#{client_width},80},,#{E:@_custom_status_right}}"
      '';
    };
  };
}
