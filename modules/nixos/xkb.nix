{ config, lib, ... }:

{
  options.smind.desktop.xkb = {
    layouts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "us+mac" "ru" ];
      example = [ "us+dvorak" "de" "fr+azerty" ];
      description = ''
        XKB keyboard layouts in "layout+variant" format.
        Use "layout" for default variant, "layout+variant" for specific variant.
        Examples: "us", "us+mac", "ru", "de+neo"
      '';
    };

    options = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "grp:caps_toggle" ];
      example = [ "grp:alt_shift_toggle" "caps:escape" ];
      description = "XKB options (e.g. layout toggle, caps behavior)";
    };

    hotkey-modifier = lib.mkOption {
      type = config.lib.xkb.modifierType;
      default = "super";
      example = "ctrl-super";
      description = ''
        Default modifier(s) for window-switching hotkeys (Tab, grave, Space) shared
        across desktop environments, as a dash-separated combination of "ctrl", "alt",
        "super", "shift" (e.g. "super", "ctrl", "ctrl-super"). Per-DE hotkey-modifier
        options default to this.
      '';
    };

    minimize-modifier = lib.mkOption {
      type = config.lib.xkb.modifierType;
      default = "ctrl-alt";
      example = "ctrl-alt-super-shift";
      description = ''
        Default modifier(s) for the minimize-window hotkey and related shortcuts
        (e.g. Classic App Switcher's hide/show-recent-app) shared across desktop
        environments, as a dash-separated combination of "ctrl", "alt", "super",
        "shift". Per-DE minimize-modifier options default to this.
      '';
    };
  };

  # Helper functions for parsing "layout+variant" format
  config.lib.xkb = {
    # Extract just the layout part from "layout+variant" or "layout"
    parseLayout = s:
      let parts = lib.splitString "+" s;
      in lib.head parts;

    # Extract just the variant part from "layout+variant", or "" if no variant
    parseVariant = s:
      let parts = lib.splitString "+" s;
      in if lib.length parts > 1 then lib.elemAt parts 1 else "";

    # Get list of layouts from config
    getLayouts = layouts: map config.lib.xkb.parseLayout layouts;

    # Get list of variants from config
    getVariants = layouts: map config.lib.xkb.parseVariant layouts;

    # Map a single modifier token to its GTK/GNOME accelerator representation
    modifierAccelTokens = {
      ctrl = "<Primary>";
      alt = "<Alt>";
      super = "<Super>";
      shift = "<Shift>";
    };

    # Option type for a modifier spec: a dash-separated combination of
    # "ctrl", "alt", "super", "shift" (e.g. "ctrl", "super", "ctrl-alt", "ctrl-alt-super-shift")
    modifierType = lib.types.addCheck lib.types.str
      (s: lib.all (t: builtins.hasAttr t config.lib.xkb.modifierAccelTokens) (lib.splitString "-" s));

    # Split a modifier spec into its individual tokens, e.g. "ctrl-alt" -> [ "ctrl" "alt" ]
    modifierTokens = spec: lib.splitString "-" spec;

    # Turn a modifier spec + key into a GTK accelerator binding, e.g. "ctrl-alt" "m" -> "<Primary><Alt>m"
    modifierBinding = spec: key:
      (lib.concatMapStrings (t: config.lib.xkb.modifierAccelTokens.${t}) (lib.splitString "-" spec)) + key;
  };
}
