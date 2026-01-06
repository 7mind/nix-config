{ config, lib, pkgs, ... }:

{
  options = {
    smind.hm.desktop.cosmic.minimal-keybindings = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Configure minimal COSMIC keybindings";
    };

    smind.hm.desktop.cosmic.dark-mode = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable dark mode in COSMIC";
    };

    smind.hm.desktop.cosmic.keyboard-layouts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "us" "ru" ];
      example = [ "us" "de" "fr" ];
      description = "XKB keyboard layouts to configure";
    };

    smind.hm.desktop.cosmic.keyboard-variant = lib.mkOption {
      type = lib.types.str;
      default = "mac,";
      example = "dvorak,";
      description = "XKB keyboard variants (comma-separated, matching layouts)";
    };

    smind.hm.desktop.cosmic.keyboard-toggle = lib.mkOption {
      type = lib.types.str;
      default = "grp:caps_toggle";
      example = "grp:alt_shift_toggle";
      description = "XKB option for keyboard layout toggle";
    };

    smind.hm.desktop.cosmic.touchpad-natural-scroll = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable natural scrolling for touchpad";
    };

    smind.hm.desktop.cosmic.roundness = lib.mkOption {
      type = lib.types.enum [ "Round" "SlightlyRound" "Square" ];
      default = "Square";
      description = "Corner radius style (Round, SlightlyRound, Square)";
    };

    smind.hm.desktop.cosmic.interface-density = lib.mkOption {
      type = lib.types.enum [ "Comfortable" "Compact" "Spacious" ];
      default = "Compact";
      description = "Interface density (Comfortable, Compact, Spacious)";
    };

    smind.hm.desktop.cosmic.active-hint-size = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Active window hint border size in pixels";
    };
  };

  config = lib.mkIf config.smind.hm.desktop.cosmic.minimal-keybindings {
    # Dark mode setting
    xdg.configFile."cosmic/com.system76.CosmicTheme.Mode/v1/is_dark".text =
      if config.smind.hm.desktop.cosmic.dark-mode then "true" else "false";

    # Keyboard layout configuration
    xdg.configFile."cosmic/com.system76.CosmicComp/v1/xkb_config".text = ''
      (
          rules: "",
          model: "",
          layout: "${lib.concatStringsSep "," config.smind.hm.desktop.cosmic.keyboard-layouts}",
          variant: "${config.smind.hm.desktop.cosmic.keyboard-variant}",
          options: Some("${config.smind.hm.desktop.cosmic.keyboard-toggle}"),
      )
    '';

    # Touchpad configuration with natural scrolling
    xdg.configFile."cosmic/com.system76.CosmicComp/v1/input_touchpad".text = ''
      (
          state: Enabled,
          click_method: Some(Clickfinger),
          scroll_config: Some((
              method: Some(TwoFinger),
              natural_scroll: Some(${if config.smind.hm.desktop.cosmic.touchpad-natural-scroll then "true" else "false"}),
              scroll_button: None,
              scroll_factor: None,
          )),
          tap_config: Some((
              enabled: true,
              button_map: Some(LeftRightMiddle),
              drag: true,
              drag_lock: false,
          )),
      )
    '';

    # Interface density (Comfortable, Compact, Spacious)
    xdg.configFile."cosmic/com.system76.CosmicTk/v1/interface_density".text =
      config.smind.hm.desktop.cosmic.interface-density;

    # Corner roundness for dark theme
    xdg.configFile."cosmic/com.system76.CosmicTheme.Dark/v1/roundness".text =
      config.smind.hm.desktop.cosmic.roundness;

    # Corner roundness for light theme
    xdg.configFile."cosmic/com.system76.CosmicTheme.Light/v1/roundness".text =
      config.smind.hm.desktop.cosmic.roundness;

    # Active window hint size
    xdg.configFile."cosmic/com.system76.CosmicComp/v1/active_hint".text =
      toString config.smind.hm.desktop.cosmic.active-hint-size;
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
        disable = mods: key: "(modifiers: [${lib.concatStringsSep ", " mods}], key: \"${key}\"): Disable";
        # Modifier-only binding (no key field) - for Super alone, etc.
        modOnly = mods: action: "(modifiers: [${lib.concatStringsSep ", " mods}]): ${action}";
        disableMod = mods: "(modifiers: [${lib.concatStringsSep ", " mods}]): Disable";
      in
      ''
        {
            // Disable Super-alone opening launcher (use Super+Space instead)
            ${disableMod ["Super"]},

            // Window management - matching GNOME minimal hotkeys
            ${kb ["Super"] "q" "Close"},
            ${disable ["Alt"] "F4"},
            ${kb ["Super"] "Tab" "System(WindowSwitcher)"},
            ${kb ["Alt"] "Tab" "System(WindowSwitcher)"},
            // Disable reversed window switching
            ${disable (["Shift" "Super"]) "Tab"},
            ${disable (["Shift" "Alt"]) "Tab"},
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

            // Launcher - use vicinae instead of COSMIC launcher
            // Using sh -c to ensure proper environment inheritance for IPC
            ${kb ["Super"] "space" "Spawn(\"sh -c 'vicinae toggle'\")"},
            // COSMIC launcher as fallback on Alt+Super+Space
            ${kb (["Alt" "Super"]) "space" "System(Launcher)"},
            ${disable ["Super"] "a"},

            // Disable accessibility shortcuts
            ${disable ["Super"] "equal"},
            ${disable ["Super"] "minus"},

            // Disable fullscreen shortcut
            ${disable ["Super"] "F11"},

            // Disable default launcher shortcut
            ${disable ["Super"] "slash"},

            // Disable workspace overview (Super+W default)
            ${disable ["Super"] "w"},

            // Disable most workspace shortcuts (minimal approach)
            ${disable ["Super"] "0"},
            ${disable ["Super"] "1"},
            ${disable ["Super"] "2"},
            ${disable ["Super"] "3"},
            ${disable ["Super"] "4"},
            ${disable ["Super"] "5"},
            ${disable ["Super"] "6"},
            ${disable ["Super"] "7"},
            ${disable ["Super"] "8"},
            ${disable ["Super"] "9"},

            // Disable move-to-workspace shortcuts
            ${disable (["Shift" "Super"]) "0"},
            ${disable (["Shift" "Super"]) "1"},
            ${disable (["Shift" "Super"]) "2"},
            ${disable (["Shift" "Super"]) "3"},
            ${disable (["Shift" "Super"]) "4"},
            ${disable (["Shift" "Super"]) "5"},
            ${disable (["Shift" "Super"]) "6"},
            ${disable (["Shift" "Super"]) "7"},
            ${disable (["Shift" "Super"]) "8"},
            ${disable (["Shift" "Super"]) "9"},

            // Disable window focus shortcuts (using switcher instead)
            ${disable ["Super"] "Left"},
            ${disable ["Super"] "Right"},
            ${disable ["Super"] "Up"},
            ${disable ["Super"] "Down"},
            ${disable ["Super"] "h"},
            ${disable ["Super"] "j"},
            ${disable ["Super"] "k"},
            ${disable ["Super"] "l"},
            ${disable ["Super"] "u"},
            ${disable ["Super"] "i"},

            // Disable move shortcuts
            ${disable (["Shift" "Super"]) "Left"},
            ${disable (["Shift" "Super"]) "Right"},
            ${disable (["Shift" "Super"]) "Up"},
            ${disable (["Shift" "Super"]) "Down"},
            ${disable (["Shift" "Super"]) "h"},
            ${disable (["Shift" "Super"]) "j"},
            ${disable (["Shift" "Super"]) "k"},
            ${disable (["Shift" "Super"]) "l"},

            // Disable resize shortcuts
            ${disable ["Super"] "r"},
            ${disable (["Shift" "Super"]) "r"},

            // Disable tiling controls (keep simple floating)
            ${disable ["Super"] "o"},
            ${disable ["Super"] "s"},
            ${disable ["Super"] "y"},
            ${disable ["Super"] "g"},
            ${disable ["Super"] "x"},
            ${disable ["Super"] "m"},

            // Disable workspace navigation
            ${disable (["Ctrl" "Super"]) "Left"},
            ${disable (["Ctrl" "Super"]) "Right"},
            ${disable (["Ctrl" "Super"]) "Up"},
            ${disable (["Ctrl" "Super"]) "Down"},
            ${disable (["Ctrl" "Super"]) "h"},
            ${disable (["Ctrl" "Super"]) "j"},
            ${disable (["Ctrl" "Super"]) "k"},
            ${disable (["Ctrl" "Super"]) "l"},

            // Disable move-to-workspace-direction
            ${disable (["Ctrl" "Shift" "Super"]) "Left"},
            ${disable (["Ctrl" "Shift" "Super"]) "Right"},
            ${disable (["Ctrl" "Shift" "Super"]) "Up"},
            ${disable (["Ctrl" "Shift" "Super"]) "Down"},
            ${disable (["Ctrl" "Shift" "Super"]) "h"},
            ${disable (["Ctrl" "Shift" "Super"]) "j"},
            ${disable (["Ctrl" "Shift" "Super"]) "k"},
            ${disable (["Ctrl" "Shift" "Super"]) "l"},

            // Disable output/monitor switching
            ${disable (["Alt" "Super"]) "Left"},
            ${disable (["Alt" "Super"]) "Right"},
            ${disable (["Alt" "Super"]) "Up"},
            ${disable (["Alt" "Super"]) "Down"},
            ${disable (["Alt" "Super"]) "h"},
            ${disable (["Alt" "Super"]) "j"},
            ${disable (["Alt" "Super"]) "k"},
            ${disable (["Alt" "Super"]) "l"},

            // Disable move-to-output
            ${disable (["Alt" "Shift" "Super"]) "Left"},
            ${disable (["Alt" "Shift" "Super"]) "Right"},
            ${disable (["Alt" "Shift" "Super"]) "Up"},
            ${disable (["Alt" "Shift" "Super"]) "Down"},
            ${disable (["Alt" "Shift" "Super"]) "h"},
            ${disable (["Alt" "Shift" "Super"]) "j"},
            ${disable (["Alt" "Shift" "Super"]) "k"},
            ${disable (["Alt" "Shift" "Super"]) "l"},

            // Disable terminal and browser launchers
            ${disable ["Super"] "t"},
            ${disable ["Super"] "b"},

            // Keep file manager
            ${kb ["Super"] "f" "System(FileBrowser)"},
        }
      '';
  };
}
