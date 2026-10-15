{ lib, minimizeModifier, extraHotkeys }:
let
  xkb = import ./xkb.nix { inherit lib; };
  empty = lib.gvariant.mkEmptyArray lib.gvariant.type.string;
in
{
  close-current-window = empty;
  enable-keyboard-shortcuts = true;
  enable-overview-effects = false;
  hide-boxpointer = false;
  hide-current-app = [ (xkb.modifierBinding minimizeModifier "h") ];
  hide-windows-from-overview = true;
  minimize-current-window = empty;
  panel-box = "left";
  position-in-box = lib.gvariant.mkInt32 1;
  quit-current-app = empty;
  show-label = true;
  show-recent-app = [ (xkb.modifierBinding minimizeModifier "u") ];
  unminimize-recent-window = empty;
} // lib.optionalAttrs extraHotkeys {
  hide-others = [ "<Control><Alt><Super>h" ];
  show-all-apps = [ "<Control><Alt><Super>u" ];
}
