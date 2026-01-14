{ config, lib, outerConfig, cfg-meta, ... }:

# This module configures KDE PowerDevil settings based on system-level options.
# Only applies on Linux where plasma-manager is available.

let

  kdeEnabled = outerConfig.smind.desktop.kde.enable or false;
  isLaptop = outerConfig.smind.isLaptop or false;
  sharedXkb = outerConfig.smind.desktop.xkb or false;
  sharedMouse = outerConfig.smind.desktop.mouse or false;
in
lib.optionalAttrs cfg-meta.isLinux {
  options = {
    smind.hm.desktop.kde.auto-suspend.enable = lib.mkOption {
      type = lib.types.bool;
      default = isLaptop;
      description = "Enable automatic suspend on idle (typically for laptops)";
    };

    smind.hm.desktop.kde.minimal-keybindings = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Configure minimal KDE keybindings for window switching";
    };

    smind.hm.desktop.kde.hotkey-modifier = lib.mkOption {
      type = lib.types.enum [ "super" "ctrl" "super+ctrl" ];
      default = "super";
      description = ''
        Modifier key for window switching hotkeys (Tab, grave, Space):
        - "super": Use Meta/Cmd key (macOS-style)
        - "ctrl": Use Ctrl key (traditional Linux/Windows style)
        - "super+ctrl": Require both Meta+Ctrl pressed together
      '';
    };

    smind.hm.desktop.kde.xkb.layouts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = sharedXkb.layouts;
      example = [ "us+dvorak" "de" "fr+azerty" ];
      description = ''
        XKB keyboard layouts for KDE in "layout+variant" format.
        Defaults to smind.desktop.xkb.layouts.
      '';
    };

    smind.hm.desktop.kde.xkb.options = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = sharedXkb.options;
      example = [ "grp:alt_shift_toggle" "caps:escape" ];
      description = ''
        XKB options for KDE (e.g. layout toggle, caps behavior).
        Defaults to smind.desktop.xkb.options.
      '';
    };

    smind.hm.desktop.kde.mouse.acceleration = lib.mkOption {
      type = lib.types.numbers.between (-1.0) 1.0;
      default = sharedMouse.acceleration;
      example = 0.2;
      description = ''
        Mouse pointer acceleration/speed for KDE.
        Defaults to smind.desktop.mouse.acceleration.
      '';
    };

    smind.hm.desktop.kde.mouse.accelProfile = lib.mkOption {
      type = lib.types.enum [ "default" "flat" "adaptive" ];
      default = sharedMouse.accelProfile;
      example = "adaptive";
      description = ''
        Mouse acceleration profile for KDE.
        Defaults to smind.desktop.mouse.accelProfile.
      '';
    };

    smind.hm.desktop.kde.mouse.naturalScroll = lib.mkOption {
      type = lib.types.bool;
      default = sharedMouse.naturalScroll;
      description = ''
        Enable natural scrolling for mouse in KDE.
        Defaults to smind.desktop.mouse.naturalScroll.
      '';
    };
  };

  # Only define plasma options on Linux where plasma-manager exists
  # Use optionalAttrs for platform check (evaluated at load time)
  # Use mkIf for config-dependent conditions (evaluated at merge time)
  config = lib.optionalAttrs cfg-meta.isLinux (lib.mkMerge [
    (lib.mkIf (kdeEnabled && !config.smind.hm.desktop.kde.auto-suspend.enable) {
      programs.plasma.powerdevil.AC.autoSuspend.action = "nothing";
    })

    # XKB keyboard layout configuration
    (lib.mkIf (kdeEnabled && config.smind.hm.desktop.kde.xkb.layouts != [ ]) {
      programs.plasma.configFile."kxkbrc"."Layout" =
        let
          xkbLib = outerConfig.lib.xkb;
          xkb = config.smind.hm.desktop.kde.xkb;
        in {
          Use = true;
          LayoutList = lib.concatStringsSep "," (xkbLib.getLayouts xkb.layouts);
          VariantList = lib.concatStringsSep "," (xkbLib.getVariants xkb.layouts);
          Options = lib.concatStringsSep "," xkb.options;
        };
    })

    # Mouse configuration
    (lib.mkIf kdeEnabled {
      programs.plasma.configFile.kcminputrc.Mouse = {
        XLbInptPointerAcceleration = config.smind.hm.desktop.kde.mouse.acceleration;
        X11LibInputXAccelProfileFlat = config.smind.hm.desktop.kde.mouse.accelProfile == "flat";
        XLbInptNaturalScroll = config.smind.hm.desktop.kde.mouse.naturalScroll;
      };
    })

    (lib.mkIf (kdeEnabled && config.smind.hm.desktop.kde.minimal-keybindings) {
      programs.plasma.shortcuts =
        let
          hotkeyMod = config.smind.hm.desktop.kde.hotkey-modifier;

          hotkeyModifier =
            if hotkeyMod == "super" then "Meta"
            else if hotkeyMod == "ctrl" then "Ctrl"
            else "Meta+Ctrl"; # super+ctrl

          mkBinding = key: "${hotkeyModifier}+${key}";
        in
        {
          kwin = {
            "Walk Through Windows" = mkBinding "Tab";
            "Walk Through Windows (Reverse)" = mkBinding "Shift+Tab";
            "Walk Through Windows Alternative" = [ ];
            "Walk Through Windows Alternative (Reverse)" = [ ];
            "Walk Through Windows of Current Application" = mkBinding "`";
            "Walk Through Windows of Current Application (Reverse)" = mkBinding "~";
            "Walk Through Windows of Current Application Alternative" = [ ];
            "Walk Through Windows of Current Application Alternative (Reverse)" = [ ];
          };
          "services/vicinae.desktop" = {
            toggle = mkBinding "Space";
          };
        };
    })
  ]);
}
