{ config, lib, pkgs, ... }:

{
  options.smind.keyboard.super-remap = {
    enable = lib.mkEnableOption "Mac-style keyboard shortcuts via kanata";
  };

  config = lib.mkIf config.smind.keyboard.super-remap.enable {
    services.kanata = {
      enable = true;
      keyboards.default = {
        devices = [ ];
        extraDefCfg = ''
          process-unmapped-keys yes
        '';
        config = ''
          ;; Caps Lock is handled by XKB grp:caps_toggle for layout switching
          ;; No kanata remapping needed
          (defsrc)

          (deflayer base)

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
  };
}
