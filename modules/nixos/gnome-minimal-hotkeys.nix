{ config, lib, pkgs, cfg-meta, ... }:

{
  options = {
    smind.desktop.gnome.minimal-hotkeys = lib.mkEnableOption "minimal GNOME hotkeys, disabling most defaults";
    smind.desktop.gnome.disable-super-drag = lib.mkEnableOption "disabling of Super key window drag modifier";
    smind.desktop.gnome.switch-applications = lib.mkEnableOption "switching applications (instead of windows) with Super-Tab";
    smind.desktop.gnome.app-window-previews = lib.mkEnableOption "switching app windows with previews with Super-Grave";
    smind.desktop.gnome.close-window-hotkey = lib.mkEnableOption "enable Super-Q close window hotkey" // { default = true; };
    smind.desktop.gnome.hotkey-modifier = lib.mkOption {
      type = config.lib.xkb.modifierType;
      default = config.smind.desktop.xkb.hotkey-modifier;
      example = "ctrl-super";
      description = ''
        Modifier(s) for window switching hotkeys (Tab, grave, Space), as a dash-separated
        combination of "ctrl", "alt", "super", "shift" (e.g. "super", "ctrl", "ctrl-super").
        Defaults to smind.desktop.xkb.hotkey-modifier.
      '';
    };
    smind.desktop.gnome.minimize-modifier = lib.mkOption {
      type = config.lib.xkb.modifierType;
      default = config.smind.desktop.xkb.minimize-modifier;
      example = "ctrl-alt-super-shift";
      description = ''
        Modifier(s) for the minimize-window hotkey and the Classic App Switcher's
        hide-current-app/show-recent-app shortcuts, as a dash-separated combination of
        "ctrl", "alt", "super", "shift". Defaults to smind.desktop.xkb.minimize-modifier.
      '';
    };
    smind.desktop.gnome.custom-keybindings = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Unique identifier for the keybinding (used in dconf path)";
          };
          binding = lib.mkOption {
            type = lib.types.str;
            example = "F5";
            description = "Key combination (e.g. 'F5', '<Super>Return', '<Primary><Alt>t')";
          };
          command = lib.mkOption {
            type = lib.types.str;
            description = "Command to execute when keybinding is pressed";
          };
          label = lib.mkOption {
            type = lib.types.str;
            description = "Human-readable label shown in GNOME settings";
          };
        };
      });
      default = [ ];
      description = "Additional custom keybindings for GNOME";
    };
  };

  config = lib.mkIf config.smind.desktop.gnome.minimal-hotkeys {

    environment.systemPackages = with pkgs; [
      gnome-shortcut-inhibitor
    ];

    programs.dconf = {
      enable = true;
      profiles.${config.smind.desktop.gnome.dconf.profile}.databases = [
        {
          lockAll = true;
          settings = import ../../lib/gnome-keybindings.nix {
            inherit lib;
            gnome = config.smind.desktop.gnome;
            vicinaeCommand = "vicinae toggle";
            ghosttyCommand = "${pkgs.glib}/bin/gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell/Extensions/RunOrRaise --method org.gnome.Shell.Extensions.RunOrRaise.Call ',ghostty,com.mitchellh.ghostty,'";
          };
        }
      ];
    };
  };
}
