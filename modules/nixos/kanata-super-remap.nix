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
        default = 10000;
        description = "Port for kanata TCP server";
      };
    };

    kanata-switcher = {
      enable = lib.mkEnableOption "kanata-switcher for automatic layer switching";

      settings = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [
          { "default" = "default"; }
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
          devices = [ ];
          port = cfg.kanata.port;
          extraDefCfg = ''
            process-unmapped-keys yes
          '';
          config = ''
            ;; Caps Lock is handled by XKB grp:caps_toggle for layout switching
            ;; No kanata remapping needed
            (defsrc)

            (deflayer default)

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
