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
  };
}
