# Modifier and layout helpers shared by NixOS and Home Manager.
# A plain attrset, not a host config value: Home Manager must not read it
# through the OS configuration.
{ lib }:
rec {
  parseLayout = s:
    let parts = lib.splitString "+" s;
    in lib.head parts;

  parseVariant = s:
    let parts = lib.splitString "+" s;
    in if lib.length parts > 1 then lib.elemAt parts 1 else "";

  getLayouts = layouts: map parseLayout layouts;

  getVariants = layouts: map parseVariant layouts;

  modifierAccelTokens = {
    ctrl = "<Primary>";
    alt = "<Alt>";
    super = "<Super>";
    shift = "<Shift>";
  };

  # Dash-separated combination of "ctrl", "alt", "super", "shift".
  modifierType = lib.types.addCheck lib.types.str
    (s: lib.all (t: builtins.hasAttr t modifierAccelTokens) (lib.splitString "-" s));

  modifierTokens = spec: lib.splitString "-" spec;

  modifierBinding = spec: key:
    (lib.concatMapStrings (t: modifierAccelTokens.${t}) (lib.splitString "-" spec)) + key;
}
