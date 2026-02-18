{ config, lib, outerConfig, cfg-meta, pkgs, ... }:

# This module configures KDE PowerDevil settings based on system-level options.
# Only applies on Linux where plasma-manager is available.

let
  defaultGtkTheme = "Breeze-Dark";
  defaultIconTheme = "breeze-dark";
  defaultCursorTheme = "breeze_cursors";
  defaultCursorSize = 36;
  defaultColorScheme = "BreezeDark";
  defaultLookAndFeel = "org.kde.breezedark.desktop";
  defaultPlasmaTheme = "breeze-dark";
  defaultWidgetStyle = "Breeze";

  defaultFontSize = 10;
  defaultSmallFontSize = 8;
  defaultFixedFontSize = 10;

  defaultSansFamily = lib.head outerConfig.smind.fonts.defaults.sansSerif;
  defaultMonoFamily = lib.head outerConfig.smind.fonts.defaults.monospace;

  kdeEnabled = outerConfig.smind.desktop.kde.enable or false;
  isLaptop = outerConfig.smind.isLaptop or false;
  sharedXkb = outerConfig.smind.desktop.xkb or false;
  sharedMouse = outerConfig.smind.desktop.mouse or false;

  kdeFontType = lib.types.submodule ({ ... }: {
    options = {
      family = lib.mkOption {
        type = lib.types.str;
        description = "Font family name.";
      };
      pointSize = lib.mkOption {
        type = lib.types.int;
        description = "Font size in points.";
      };
    };
  });
in
lib.optionalAttrs cfg-meta.isLinux {
  options = {
    smind.hm.desktop.kde.auto-suspend.enable = lib.mkOption {
      type = lib.types.bool;
      default = isLaptop;
      description = "Enable automatic suspend on idle (typically for laptops)";
    };

    smind.hm.desktop.kde.minimal-keybindings = lib.mkEnableOption "minimal KDE keybindings for window switching";

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

    smind.hm.desktop.kde.theme = {
      gtkTheme = lib.mkOption {
        type = lib.types.str;
        default = defaultGtkTheme;
        description = "GTK theme name to apply in KDE session.";
      };

      iconTheme = lib.mkOption {
        type = lib.types.str;
        default = defaultIconTheme;
        description = "Icon theme name for KDE and GTK apps.";
      };

      cursorTheme = lib.mkOption {
        type = lib.types.str;
        default = defaultCursorTheme;
        description = "Cursor theme name for KDE and GTK apps.";
      };

      cursorSize = lib.mkOption {
        type = lib.types.int;
        default = defaultCursorSize;
        description = "Cursor size for KDE and GTK apps.";
      };

      colorScheme = lib.mkOption {
        type = lib.types.str;
        default = defaultColorScheme;
        description = "KDE color scheme name.";
      };

      lookAndFeel = lib.mkOption {
        type = lib.types.str;
        default = defaultLookAndFeel;
        description = "KDE Look-and-Feel package name.";
      };

      plasmaTheme = lib.mkOption {
        type = lib.types.str;
        default = defaultPlasmaTheme;
        description = "Plasma theme name.";
      };

      widgetStyle = lib.mkOption {
        type = lib.types.str;
        default = defaultWidgetStyle;
        description = "KDE widget style name.";
      };
    };

    smind.hm.desktop.kde.gtk-restore.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Restore GTK files from Home Manager after KDE session ends.";
    };

    smind.hm.desktop.kde.fonts = {
      general = lib.mkOption {
        type = kdeFontType;
        default = {
          family = defaultSansFamily;
          pointSize = defaultFontSize;
        };
        description = "General KDE font settings.";
      };

      fixedWidth = lib.mkOption {
        type = kdeFontType;
        default = {
          family = defaultMonoFamily;
          pointSize = defaultFixedFontSize;
        };
        description = "Fixed width KDE font settings.";
      };

      small = lib.mkOption {
        type = kdeFontType;
        default = {
          family = defaultSansFamily;
          pointSize = defaultSmallFontSize;
        };
        description = "Small KDE font settings.";
      };

      toolbar = lib.mkOption {
        type = kdeFontType;
        default = {
          family = defaultSansFamily;
          pointSize = defaultFontSize;
        };
        description = "Toolbar KDE font settings.";
      };

      menu = lib.mkOption {
        type = kdeFontType;
        default = {
          family = defaultSansFamily;
          pointSize = defaultFontSize;
        };
        description = "Menu KDE font settings.";
      };

      windowTitle = lib.mkOption {
        type = kdeFontType;
        default = {
          family = defaultSansFamily;
          pointSize = defaultFontSize;
        };
        description = "Window title KDE font settings.";
      };
    };
  };

  # Only define plasma options on Linux where plasma-manager exists
  # Use optionalAttrs for platform check (evaluated at load time)
  # Use mkIf for config-dependent conditions (evaluated at merge time)
  config = lib.optionalAttrs cfg-meta.isLinux (lib.mkMerge [
    (lib.mkIf kdeEnabled {
      assertions = [
        {
          assertion = config.smind.hm.desktop.kde.theme.gtkTheme != "";
          message = "smind.hm.desktop.kde.theme.gtkTheme must be set";
        }
        {
          assertion = config.smind.hm.desktop.kde.theme.iconTheme != "";
          message = "smind.hm.desktop.kde.theme.iconTheme must be set";
        }
        {
          assertion = config.smind.hm.desktop.kde.theme.cursorTheme != "";
          message = "smind.hm.desktop.kde.theme.cursorTheme must be set";
        }
        {
          assertion = config.smind.hm.desktop.kde.theme.colorScheme != "";
          message = "smind.hm.desktop.kde.theme.colorScheme must be set";
        }
        {
          assertion = config.smind.hm.desktop.kde.theme.lookAndFeel != "";
          message = "smind.hm.desktop.kde.theme.lookAndFeel must be set";
        }
        {
          assertion = config.smind.hm.desktop.kde.theme.plasmaTheme != "";
          message = "smind.hm.desktop.kde.theme.plasmaTheme must be set";
        }
        {
          assertion = config.smind.hm.desktop.kde.theme.widgetStyle != "";
          message = "smind.hm.desktop.kde.theme.widgetStyle must be set";
        }
        {
          assertion = config.smind.hm.desktop.kde.fonts.general.family != "";
          message = "smind.hm.desktop.kde.fonts.general.family must be set";
        }
        {
          assertion = config.smind.hm.desktop.kde.fonts.fixedWidth.family != "";
          message = "smind.hm.desktop.kde.fonts.fixedWidth.family must be set";
        }
        {
          assertion = config.smind.hm.desktop.kde.fonts.small.family != "";
          message = "smind.hm.desktop.kde.fonts.small.family must be set";
        }
        {
          assertion = config.smind.hm.desktop.kde.fonts.toolbar.family != "";
          message = "smind.hm.desktop.kde.fonts.toolbar.family must be set";
        }
        {
          assertion = config.smind.hm.desktop.kde.fonts.menu.family != "";
          message = "smind.hm.desktop.kde.fonts.menu.family must be set";
        }
        {
          assertion = config.smind.hm.desktop.kde.fonts.windowTitle.family != "";
          message = "smind.hm.desktop.kde.fonts.windowTitle.family must be set";
        }
        {
          assertion = config.smind.hm.desktop.kde.fonts.general.pointSize > 0;
          message = "smind.hm.desktop.kde.fonts.general.pointSize must be > 0";
        }
        {
          assertion = config.smind.hm.desktop.kde.fonts.fixedWidth.pointSize > 0;
          message = "smind.hm.desktop.kde.fonts.fixedWidth.pointSize must be > 0";
        }
        {
          assertion = config.smind.hm.desktop.kde.fonts.small.pointSize > 0;
          message = "smind.hm.desktop.kde.fonts.small.pointSize must be > 0";
        }
        {
          assertion = config.smind.hm.desktop.kde.fonts.toolbar.pointSize > 0;
          message = "smind.hm.desktop.kde.fonts.toolbar.pointSize must be > 0";
        }
        {
          assertion = config.smind.hm.desktop.kde.fonts.menu.pointSize > 0;
          message = "smind.hm.desktop.kde.fonts.menu.pointSize must be > 0";
        }
        {
          assertion = config.smind.hm.desktop.kde.fonts.windowTitle.pointSize > 0;
          message = "smind.hm.desktop.kde.fonts.windowTitle.pointSize must be > 0";
        }
      ];
    })

    (lib.mkIf (kdeEnabled && !config.smind.hm.desktop.kde.auto-suspend.enable) {
      programs.plasma.powerdevil.AC.autoSuspend.action = "nothing";
    })

    # XKB keyboard layout configuration
    (lib.mkIf (kdeEnabled && config.smind.hm.desktop.kde.xkb.layouts != [ ]) {
      programs.plasma.input.keyboard =
        let
          xkbLib = outerConfig.lib.xkb;
          xkb = config.smind.hm.desktop.kde.xkb;
          layouts = xkbLib.getLayouts xkb.layouts;
          variants = xkbLib.getVariants xkb.layouts;
          mkLayout = layout: variant: { layout = layout; } // (if variant == "" then { } else { variant = variant; });
        in
        {
          layouts = lib.zipListsWith mkLayout layouts variants;
          options = xkb.options;
        };
    })

    # Mouse configuration (no idiomatic option without vendor/product IDs)
    (lib.mkIf kdeEnabled {
      programs.plasma.configFile.kcminputrc.Mouse = {
        XLbInptPointerAcceleration = config.smind.hm.desktop.kde.mouse.acceleration;
        X11LibInputXAccelProfileFlat = config.smind.hm.desktop.kde.mouse.accelProfile == "flat";
        XLbInptNaturalScroll = config.smind.hm.desktop.kde.mouse.naturalScroll;
      };
    })

    (lib.mkIf kdeEnabled {
      programs.plasma.workspace = {
        colorScheme = config.smind.hm.desktop.kde.theme.colorScheme;
        iconTheme = config.smind.hm.desktop.kde.theme.iconTheme;
        lookAndFeel = config.smind.hm.desktop.kde.theme.lookAndFeel;
        theme = config.smind.hm.desktop.kde.theme.plasmaTheme;
        widgetStyle = config.smind.hm.desktop.kde.theme.widgetStyle;
        cursor = {
          theme = config.smind.hm.desktop.kde.theme.cursorTheme;
          size = config.smind.hm.desktop.kde.theme.cursorSize;
        };
      };

      programs.plasma.configFile.kded5rc."Module-gtkconfig".autoload = outerConfig.smind.desktop.kde.kde-gtk-config.enable;
    })

    (lib.mkIf kdeEnabled {
      programs.plasma.fonts = {
        general = config.smind.hm.desktop.kde.fonts.general;
        fixedWidth = config.smind.hm.desktop.kde.fonts.fixedWidth;
        small = config.smind.hm.desktop.kde.fonts.small;
        toolbar = config.smind.hm.desktop.kde.fonts.toolbar;
        menu = config.smind.hm.desktop.kde.fonts.menu;
        windowTitle = config.smind.hm.desktop.kde.fonts.windowTitle;
      };
    })

    (lib.mkIf (kdeEnabled && config.smind.hm.desktop.kde.gtk-restore.enable) {
      xdg.configFile."smind/hm-home-files-marker".text = "";

      # On KDE logout, restore specific GTK files/dirs to the exact HM-managed
      # state from the current Home Manager activation package (home-files). If a
      # path is not managed by HM, it is removed. This prevents kde-gtk-config's
      # writes (gtkrc, gtk.css/colors.css, window_decorations.css, assets,
      # xsettingsd.conf) from persisting into GNOME sessions.
      systemd.user.services.smind-kde-gtk-theme =
        let
          restoreScript = pkgs.writeShellScript "smind-kde-gtk-restore" ''
            set -euo pipefail
            home="''${HOME:?}"
            config_dir="''${XDG_CONFIG_HOME:-$home/.config}"
            readlink_bin=${lib.escapeShellArg "${pkgs.coreutils}/bin/readlink"}

            find_hm_root() {
              local marker
              local target
              local hm_root
              marker="$config_dir/smind/hm-home-files-marker"
              if [ -L "$marker" ]; then
                target="$("$readlink_bin" "$marker")"
                case "$target" in
                  */.config/smind/hm-home-files-marker)
                    hm_root="''${target%/.config/smind/hm-home-files-marker}"
                    printf '%s\n' "$hm_root"
                    return 0
                    ;;
                esac
              fi
              return 1
            }

            if ! hm_root="$(find_hm_root)"; then
              echo >&2 "smind-kde-gtk-restore: unable to locate Home Manager home-files root"
              exit 1
            fi

            if [ ! -e "$hm_root" ]; then
              echo >&2 "smind-kde-gtk-restore: hm-root not found: $hm_root"
              exit 1
            fi

            log() {
              echo "smind-kde-gtk-restore: $*"
            }

            log "hm_root=$hm_root"

            restore_path() {
              local target="$1"
              local rel="''${target#"$home"/}"
              local source="$hm_root/$rel"
              local source_exists=0
              local target_exists=0
              if [ -e "$source" ]; then
                source_exists=1
              fi
              if [ -e "$target" ]; then
                target_exists=1
              fi
              log "restore target=$target source=$source source_exists=$source_exists target_exists=$target_exists"
              if [ -e "$source" ]; then
                mkdir -p "$(dirname "$target")"
                rm -rf "$target"
                cp -a "$source" "$target"
              else
                rm -rf "$target"
              fi
            }

            restore_path "$home/.gtkrc-2.0"
            restore_path "$config_dir/gtkrc-2.0"
            restore_path "$config_dir/gtkrc"
            restore_path "$config_dir/gtk-3.0/settings.ini"
            restore_path "$config_dir/gtk-3.0/gtk.css"
            restore_path "$config_dir/gtk-3.0/colors.css"
            restore_path "$config_dir/gtk-3.0/window_decorations.css"
            restore_path "$config_dir/gtk-3.0/assets"
            restore_path "$config_dir/gtk-4.0/settings.ini"
            restore_path "$config_dir/gtk-4.0/gtk.css"
            restore_path "$config_dir/gtk-4.0/colors.css"
            restore_path "$config_dir/gtk-4.0/window_decorations.css"
            restore_path "$config_dir/gtk-4.0/assets"
            restore_path "$config_dir/xsettingsd/xsettingsd.conf"
          '';
        in
        {
          Unit = {
            Description = "Restore GTK files from Home Manager after KDE session";
            After = [ "graphical-session.target" ];
            PartOf = [ "graphical-session.target" ];
            ConditionEnvironment = "KDE_FULL_SESSION=true";
          };

          Service = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
            ExecStop = "${restoreScript}";
          };

          Install = {
            WantedBy = [ "graphical-session.target" ];
          };
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
