{ config, lib, cfg-meta, ... }:

{
  options = {
    smind.hm.wezterm.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.wezterm.enable {
    programs.wezterm =
      let
        font_size = if cfg-meta.isDarwin then 14 else 10;
        initial_rows = if cfg-meta.isDarwin then 40 else 60;
      in
      {
        # use  wezterm show-keys --lua
        enable = true;
        enableZshIntegration = true;
        extraConfig = ''
            return {
              -- front_end = "WebGpu",
              font = wezterm.font("JetBrains Mono"),
              font_size = ${toString font_size},
              initial_cols = 160,
              initial_rows = ${toString initial_rows},
              scrollback_lines = 10000;
              window_padding = {
                bottom = "5px",
                left = "1cell",
                right = "1cell",
                top = "5px",
              };
              window_decorations = "TITLE|RESIZE";


              colors = {
                 split = 'aqua',
              };

              -- to fix borders under gnome
              enable_wayland = false;

              keys = {
                  {
                    key="c",
                    mods="CTRL",
                    action = wezterm.action_callback(function(window, pane)
                      local has_selection = window:get_selection_text_for_pane(pane) ~= ""
                      if has_selection then
                        window:perform_action(
                          wezterm.action{CopyTo="ClipboardAndPrimarySelection"},
                          pane)
                        window:perform_action("ClearSelection", pane)
                      else
                        window:perform_action(
                          wezterm.action{SendKey={key="c", mods="CTRL"}},
                          pane)
                      end
                    end)
                },
                {
                  key="c",
                  mods="CTRL|SHIFT",
                  action = wezterm.action{SendKey={key="c", mods="CTRL"}}
                },
                {
                  key="v",
                  mods="CTRL",
                  action=wezterm.action.PasteFrom('Clipboard'),
                },
                {
                  key="v",
                  mods="CTRL|SHIFT",
                  action=wezterm.action{SendKey={key="v", mods="CTRL"}},
                },

                {key="d", mods="SHIFT|SUPER", action = wezterm.action.SplitHorizontal {domain='CurrentPaneDomain'} },
                {key="d", mods="SUPER", action = wezterm.action.SplitVertical {domain='CurrentPaneDomain'} },

                {key="UpArrow", mods="SUPER", action = wezterm.action.ActivatePaneDirection 'Up' },
                {key="DownArrow", mods="SUPER", action = wezterm.action.ActivatePaneDirection 'Down' },
                {key="LeftArrow", mods="SUPER", action = wezterm.action.ActivatePaneDirection 'Left' },
                {key="RightArrow", mods="SUPER", action = wezterm.action.ActivatePaneDirection 'Right' },

                {key="[", mods="SUPER", action = wezterm.action.ActivateTabRelative (-1) },
                {key="]", mods="SUPER", action = wezterm.action.ActivateTabRelative (1) },

                {key="UpArrow", mods="SHIFT|SUPER", action = wezterm.action.AdjustPaneSize {"Up", 1} },
                {key="DownArrow", mods="SHIFT|SUPER", action = wezterm.action.AdjustPaneSize {"Down", 1} },
                {key="LeftArrow", mods="SHIFT|SUPER", action = wezterm.action.AdjustPaneSize {"Left", 1} },
                {key="RightArrow", mods="SHIFT|SUPER", action = wezterm.action.AdjustPaneSize {"Right", 1} },

                { key = 'PageUp', mods = 'SHIFT', action = wezterm.action.ScrollByPage(-0.5) },
                { key = 'PageDown', mods = 'SHIFT', action = wezterm.action.ScrollByPage(0.5) },

                {key="d", mods="SHIFT|ALT|CTRL", action="ShowDebugOverlay"},
              },

              key_tables = {
                search_mode = {
                  { key = 'g', mods = 'SUPER', action = wezterm.action.CopyMode 'PriorMatch' },
                  { key = 'g', mods = 'SHIFT|SUPER', action = wezterm.action.CopyMode 'NextMatch' },
                  { key = 'c', mods = 'CTRL', action = wezterm.action.CopyMode 'Close' },
                  { key = 'Backspace', mods = 'SUPER', action = wezterm.action.CopyMode 'ClearPattern' },
                  { key = 'r', mods = 'SUPER', action = wezterm.action.CopyMode 'CycleMatchType' },
                }
              },

              mouse_bindings = {
                {
                  event = { Down = { streak = 1, button = { WheelUp = 1 } } },
                  action = wezterm.action.ScrollByLine(-2),
                },

                {
                  event = { Down = { streak = 1, button = { WheelDown = 1 } } },
                  action = wezterm.action.ScrollByLine(2),
                },

                -- Disable the default click behavior
                {
                  event = { Up = { streak = 1, button = "Left"} },
                  mods = "NONE",
                  action = wezterm.action.DisableDefaultAssignment,
                },
                -- Ctrl-click will open the link under the mouse cursor
                {
                    event = { Up = { streak = 1, button = "Left" } },
                    mods = "CTRL",
                    action = wezterm.action.OpenLinkAtMouseCursor,
                },
                -- Disable the Ctrl-click down event to stop programs from seeing it when a URL is clicked
                {
                    event = { Down = { streak = 1, button = "Left" } },
                    mods = "CTRL",
                    action = wezterm.action.Nop,
                },

              },
          }
        '';
      };
  };
}
