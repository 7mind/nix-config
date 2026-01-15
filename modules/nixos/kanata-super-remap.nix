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
        '';
        description = "kanata service extraDefCfg";
      };

      config = lib.mkOption {
        type = lib.types.str;
        default = ''
          ;; Caps Lock is handled by XKB grp:caps_toggle for layout switching
          ;; No kanata remapping needed
          (defsrc)

          (deflayer default)

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

          (deftemplate mk-override (required-mods key result)
            $key (switch
                  ((and $required-mods (not (t! mods-except ($required-mods))))) $result break
                  () $key break)
          )

          ;; Emacs-style: Ctrl+A → Home, Ctrl+E → End
          (deflayermap (firefox)
            ;; Long version
            a (switch
                ((and (or lctl rctl) (not lsft rsft lalt ralt lmet rmet))) (unmod home) break
                () a break)
            ;; With mk-override macro
            (t! mk-override (or lctl rctl) e (unmod end))
            ;; Example mk-override: Super+G → Ctrl+Space
            ;; (t! mk-override (or lmet rmet) g (unmod lctl spc))
          )

          ;; Mac-style: Super+Key → Ctrl+Key (only for specific keys)
          ;; Super+Tab, Super+Q, etc. are NOT remapped (handled by GNOME/desktop)
          (defoverrides
            ;; Text editing
            (lmet a) (lctl a)    ;; Select all
            (lmet c) (lctl c)    ;; Copy
            (lmet v) (lctl v)    ;; Paste
            (lmet x) (lctl x)    ;; Cut
            (lmet z) (lctl z)    ;; Undo
            ;; File operations
            (lmet s) (lctl s)    ;; Save
            (lmet o) (lctl o)    ;; Open
            (lmet p) (lctl p)    ;; Print / Command palette
            ;; Navigation
            (lmet f) (lctl f)    ;; Find
            (lmet l) (lctl l)    ;; Address bar / Go to line
            (lmet r) (lctl r)    ;; Refresh
            ;; Window/tab management
            (lmet t) (lctl t)    ;; New tab
            (lmet n) (lctl n)    ;; New window
            (lmet w) (lctl w)    ;; Close tab/window
            ;; Super+Shift combinations
            (lmet lsft z) (lctl lsft z)  ;; Redo
            (lmet lsft f) (lctl lsft f)  ;; Find in files
            (lmet lsft t) (lctl lsft t)  ;; Reopen closed tab
            (lmet lsft n) (lctl lsft n)  ;; New incognito/private window
            (lmet lsft p) (lctl lsft p)  ;; Command palette (VS Code)
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
          { "default" = "default"; }
          {
            "class" = "firefox";
            "layer" = "firefox";
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
      services.kanata = {
        enable = true;
        keyboards.default = {
          devices = cfg.kanata.devices;
          port = cfg.kanata.port;
          extraDefCfg = cfg.kanata.extraDefCfg;
          config = cfg.kanata.config;
        };
      };
    })

    (lib.mkIf (cfg.kanata-switcher.enable) {
      services.kanata-switcher = {
        enable = true;
        kanataPort = cfg.kanata.port;
        gnomeExtension.enable = false; # managed in gnome-extensions.nix
        settings = cfg.kanata-switcher.settings;
      };
    })
  ];
}
