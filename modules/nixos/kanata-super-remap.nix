{ config, lib, pkgs, ... }:

let
  cfg = config.smind.keyboard.super-remap;
in
{
  options.smind.keyboard.super-remap = {
    enable = lib.mkEnableOption "Mac-style keyboard shortcuts via kanata";

    kanata = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 22334;
        description = "Port for kanata TCP server";
      };

      devices = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "kanata service devices";
      };

      extraDefCfg = lib.mkOption {
        type = lib.types.str;
        default = ''
          process-unmapped-keys yes
          delegate-to-first-layer true
          concurrent-tap-hold true
        '';
        description = "kanata service extraDefCfg";
      };

      config = lib.mkOption {
        type = lib.types.str;
        # Kanata simulator for testing: https://jtroo.github.io/
        default = ''
          ;; Caps Lock is handled by XKB grp:caps_toggle for layout switching
          ;; No kanata remapping needed
          (defsrc)

          ${config.lib.kanata.mkOverrideMacro}

          ;; Mac-style: Super+Key → Ctrl+Key (only for specific keys)
          ;; Super+Tab, Super+Q, etc. are NOT remapped (handled by GNOME/desktop)
          (deflayermap (default)
            ;; Text editing
            (t! mk-override (or lmet rmet) a (unmod lctl a))   ;; Select all
            (t! mk-override (or lmet rmet) c (unmod lctl c))   ;; Copy
            (t! mk-override (or lmet rmet) v (unmod lctl v))   ;; Paste
            (t! mk-override (or lmet rmet) x (unmod lctl x))   ;; Cut
            (t! mk-override (or lmet rmet) z (unmod lctl z))   ;; Undo
            ;; File operations
            (t! mk-override (or lmet rmet) s (unmod lctl s))   ;; Save
            (t! mk-override (or lmet rmet) o (unmod lctl o))   ;; Open
            (t! mk-override (or lmet rmet) p (unmod lctl p))   ;; Print / Command palette
            ;; Navigation
            (t! mk-override (or lmet rmet) f (unmod lctl f))   ;; Find
            (t! mk-override (or lmet rmet) l (unmod lctl l))   ;; Address bar / Go to line
            (t! mk-override (or lmet rmet) r (unmod lctl r))   ;; Refresh
            ;; Window/tab management
            (t! mk-override (or lmet rmet) t (unmod lctl t))   ;; New tab
            (t! mk-override (or lmet rmet) n (unmod lctl n))   ;; New window
            (t! mk-override (or lmet rmet) w (unmod lctl w))   ;; Close tab/window
            ;; Shift layer
            lsft (multi (layer-while-held shift-layer) lsft)
            rsft (multi (layer-while-held shift-layer) rsft)

            ;; (t! mk-override (or lctl rctl) a (unmod home)) ;; ctrl-a => home
            ;; (t! mk-override (or lctl rctl) e (unmod end))  ;; ctrl-e => end
          )

          (deflayermap (shift-layer)
            ;; Super+Shift combinations
            (t! mk-override (and (or lmet rmet) (or lsft rsft)) z (unmod lctl lsft z))  ;; Redo
            (t! mk-override (and (or lmet rmet) (or lsft rsft)) f (unmod lctl lsft f))  ;; Find in files
            (t! mk-override (and (or lmet rmet) (or lsft rsft)) t (unmod lctl lsft t))  ;; Reopen closed tab
            (t! mk-override (and (or lmet rmet) (or lsft rsft)) n (unmod lctl lsft n))  ;; New incognito/private window
            (t! mk-override (and (or lmet rmet) (or lsft rsft)) p (unmod lctl lsft p))  ;; Command palette (VS Code)
          )

          (deflayermap (terminal)
            a a
            e e
          )
          ;; Emacs-style: Ctrl+A → Home, Ctrl+E → End
          (deflayermap (browser)
            ;; Long version
            ;; a (switch
            ;;    ((and (or lctl rctl) (not lsft rsft lalt ralt lmet rmet))) (unmod home) break
            ;;    () a break)

            ;; Example mk-override (without Shift): Super+G → Ctrl+Space
            ;; (t! mk-override (or lmet rmet) g (unmod lctl spc))

            ;; Example mk-override (with Shift): Super+Shift+B → Ctrl+Space
            ;; (t! mk-override (and (or lmet rmet) (or lsft rsft)) b (unmod lctl spc))
          )
        '';
        description = "kanata service config";
      };
    };

    kanata-switcher = {
      enable = lib.mkEnableOption "kanata-switcher for automatic layer switching";

      settings = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [
          {
            "default" = "default";
          }
          {
            "class" = "firefox|chromium-browser|brave-browser";
            "layer" = "browser";
          }
          {
            "class" = "kitty|alacritty|wezterm|com.mitchellh.ghostty|code|jetbrains|codium|VSCodium";
            "layer" = "terminal";
          }
        ];
        description = "Layer switching rules for kanata-switcher";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.systemPackages = [ config.services.kanata.package ];

      services.kanata = {
        enable = true;
        keyboards.default = {
          devices = cfg.kanata.devices;
          port = cfg.kanata.port;
          extraDefCfg = cfg.kanata.extraDefCfg;
          config = cfg.kanata.config;
        };
      };

      # Restart kanata when config changes
      systemd.services.kanata-default.restartTriggers = [
        cfg.kanata.config
        cfg.kanata.extraDefCfg
      ];

      lib.kanata.mkOverrideMacro = ''
        (deftemplate mods-except (req-list)
          (or
            (if-not-in-list lsft $req-list lsft)
            (if-not-in-list rsft $req-list rsft)
            (if-not-in-list lalt $req-list lalt)
            (if-not-in-list ralt $req-list ralt)
            (if-not-in-list lctl $req-list lctl)
            (if-not-in-list rctl $req-list rctl)
            (if-not-in-list lmet $req-list lmet)
            (if-not-in-list rmet $req-list rmet)
          )
        )

        (deftemplate mk-override-ext (required-mods-expr required-mods-list key result)
          $key (switch
                ((and $required-mods-expr (not (t! mods-except ($required-mods-list))))) $result break
                () $key break)
        )

        (deftemplate mk-override (required-mods key result)
          (t! mk-override-ext $required-mods $required-mods $key $result)
        )
      '';
    })

    (lib.mkIf (cfg.kanata-switcher.enable) {
      services.kanata-switcher = {
        enable = true;
        kanataPort = cfg.kanata.port;
        gnomeExtension.enable = false; # managed in gnome-extensions.nix
        settings = cfg.kanata-switcher.settings;
      };

      # Restart kanata-switcher when settings change
      systemd.user.services.kanata-switcher.restartTriggers = [
        (builtins.toJSON cfg.kanata-switcher.settings)
      ];
    })
  ];
}
