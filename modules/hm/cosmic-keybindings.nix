{ config, lib, pkgs, ... }:

{
  options = {
    smind.hm.cosmic.minimal-keybindings = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.cosmic.minimal-keybindings {
    # COSMIC keybindings are stored in:
    # ~/.config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom
    #
    # The format is RON (Rusty Object Notation):
    # {
    #   (modifiers: [Super], key: "q"): Close,
    #   ...
    # }

    xdg.configFile."cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom".text =
      let
        # Helper to generate RON keybinding entries
        # Modifiers: Super, Alt, Ctrl, Shift
        kb = mods: key: action: "(modifiers: [${lib.concatStringsSep ", " mods}], key: \"${key}\"): ${action}";
        empty = mods: key: "(modifiers: [${lib.concatStringsSep ", " mods}], key: \"${key}\"): Disable";
      in
      ''
        {
            // Window management - matching GNOME minimal hotkeys
            ${kb ["Super"] "q" "Close"},
            ${kb ["Alt"] "F4" "Close"},
            ${kb ["Super"] "Tab" "System(WindowSwitcher)"},
            ${kb ["Alt"] "Tab" "System(WindowSwitcher)"},
            ${kb ["Super"] "grave" "System(WindowSwitcherSameApp)"},
            ${kb (["Ctrl" "Alt"]) "f" "Maximize"},
            ${kb (["Ctrl" "Alt"]) "m" "Minimize"},

            // System actions
            ${kb (["Shift" "Super"]) "l" "System(LockScreen)"},
            ${kb ["Super"] "Escape" "System(LockScreen)"},

            // Screenshots - matching GNOME
            ${kb (["Shift" "Super"]) "3" "System(Screenshot)"},
            ${kb (["Shift" "Super"]) "4" "System(ScreenshotUi)"},
            ${kb [] "Print" "System(Screenshot)"},

            // Launcher
            ${kb ["Super"] "space" "System(Launcher)"},
            ${kb (["Alt" "Super"]) "space" "ToggleOverview"},
            ${kb ["Super"] "a" "System(AppLibrary)"},

            // Disable most workspace shortcuts (minimal approach)
            ${empty ["Super"] "1"},
            ${empty ["Super"] "2"},
            ${empty ["Super"] "3"},
            ${empty ["Super"] "4"},
            ${empty ["Super"] "5"},
            ${empty ["Super"] "6"},
            ${empty ["Super"] "7"},
            ${empty ["Super"] "8"},
            ${empty ["Super"] "9"},

            // Disable window focus shortcuts (using switcher instead)
            ${empty ["Super"] "Left"},
            ${empty ["Super"] "Right"},
            ${empty ["Super"] "Up"},
            ${empty ["Super"] "Down"},
            ${empty ["Super"] "h"},
            ${empty ["Super"] "j"},
            ${empty ["Super"] "k"},
            ${empty ["Super"] "l"},

            // Disable move shortcuts
            ${empty (["Shift" "Super"]) "Left"},
            ${empty (["Shift" "Super"]) "Right"},
            ${empty (["Shift" "Super"]) "Up"},
            ${empty (["Shift" "Super"]) "Down"},
            ${empty (["Shift" "Super"]) "h"},
            ${empty (["Shift" "Super"]) "j"},
            ${empty (["Shift" "Super"]) "k"},
            ${empty (["Shift" "Super"]) "l"},

            // Keep terminal launcher
            ${kb ["Super"] "t" "System(Terminal)"},
        }
      '';
  };
}
