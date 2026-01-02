{ config, lib, pkgs, ... }:

{
  options = {
    smind.keyboard.super-remap.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Remap Super key taps to input source switching via keyd";
    };
  };

  config = lib.mkIf config.smind.keyboard.super-remap.enable {
    # Add keyd to PATH for debugging (keyd monitor, keyd list, etc.)
    environment.systemPackages = [ pkgs.keyd ];

    services.keyd = {
      enable = true;
      keyboards.default = {
        # Note: "*" only matches keyboards, mouse/touchpad devices must be explicit
        # Common touchpad IDs can be found with: keyd monitor
        ids = [ "*" "093a:0274" ];  # 093a:0274 = Framework 16 touchpad (PIXA3854)
        settings = {
          main = {
            # Caps Lock as Hyper key (Ctrl+Alt+Super+Space)
            capslock = "macro(leftcontrol+leftalt+leftmeta+space)";
          };

          # Shift+Caps Lock toggles actual Caps Lock
          "shift" = {
            capslock = "capslock";
          };

          # Mac-style Super key remaps to Ctrl equivalents
          # Note: "meta" layer (not "meta:M") so Super key is NOT passed through
          "meta" = {
            # Mouse - Super+Click opens links in new tab (like Ctrl+Click)
            leftmouse = "C-leftmouse";
            # Text editing
            a = "macro(leftcontrol+a)";  # Select all
            c = "macro(leftcontrol+c)";  # Copy
            v = "macro(leftcontrol+v)";  # Paste
            x = "macro(leftcontrol+x)";  # Cut
            z = "macro(leftcontrol+z)";  # Undo
            # File operations
            s = "macro(leftcontrol+s)";  # Save
            o = "macro(leftcontrol+o)";  # Open
            p = "macro(leftcontrol+p)";  # Print / Command palette
            # Navigation
            f = "macro(leftcontrol+f)";  # Find
            l = "macro(leftcontrol+l)";  # Address bar / Go to line
            r = "macro(leftcontrol+r)";  # Refresh
            # Window/tab management
            t = "macro(leftcontrol+t)";  # New tab
            n = "macro(leftcontrol+n)";  # New window
            w = "macro(leftcontrol+w)";  # Close tab/window
            # q = "macro(leftcontrol+q)";  # Quit (commented - too dangerous)
          };

          "meta+shift" = {
            z = "macro(leftcontrol+leftshift+z)";  # Redo
            f = "macro(leftcontrol+leftshift+f)";  # Find in files
            t = "macro(leftcontrol+leftshift+t)";  # Reopen closed tab
            n = "macro(leftcontrol+leftshift+n)";  # New incognito/private window
            p = "macro(leftcontrol+leftshift+p)";  # Command palette (VS Code)
          };
        };
      };
    };
  };
}
