{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  cfg = config.smind.dictation;
  shortcut = {
    name = "dictation-toggle";
    label = "Toggle Qwen dictation";
    binding = cfg.gnome.shortcut;
    command = "${lib.getExe pkgs.hyprwhspr} record toggle";
  };
  shortcutPath = "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/${shortcut.name}";
  waveformExtension = pkgs.callPackage ../../pkg/hyprwhspr/waveform.nix {
    src = inputs.hyprwhspr;
    shellVersion = config.smind.desktop.gnome.extensions.shellVersion;
  };
in
{
  imports = [
    (import (inputs.hyprwhspr + "/nix/module.nix") { defaultPackage = pkgs.hyprwhspr; })
  ];

  options.smind.dictation = {
    enable = lib.mkEnableOption "offline Qwen3-ASR desktop dictation";
    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.optional (config.smind.host.owner != null) config.smind.host.owner;
      description = "Users with dictation configuration and input-device access.";
    };
    model = lib.mkOption {
      type = lib.types.enum [
        "0.6b-q8_0"
        "1.7b-q8_0"
      ];
      default = "1.7b-q8_0";
      description = "Qwen3-ASR model downloaded on first service start.";
    };
    device = lib.mkOption {
      type = lib.types.enum [
        "cpu"
        "vulkan"
      ];
      default = "vulkan";
      description = "Inference runtime used for Qwen3-ASR.";
    };
    gnome.enable = lib.mkEnableOption "GNOME dictation shortcut and accessibility integration" // {
      default = cfg.enable && config.smind.desktop.gnome.enable;
    };
    gnome.shortcut = lib.mkOption {
      type = lib.types.str;
      default = "<Super><Control>d";
      description = "GNOME shortcut that starts or stops dictation.";
    };
    gnome.waveform.enable = lib.mkEnableOption "GNOME Shell dictation waveform overlay" // {
      default = cfg.gnome.enable;
    };
  };

  config = lib.mkIf cfg.enable {
    services.hyprwhspr = {
      enable = true;
      inherit (cfg) users;
    };

    home-manager.users = lib.genAttrs cfg.users (_: import ../../lib/dictation-home.nix {
      inherit (cfg) model device;
      externalBindings = cfg.gnome.enable;
    });

    systemd.user.services.hyprwhspr.serviceConfig = {
      ExecStartPre = lib.mkBefore [ "${lib.getExe pkgs.hyprwhspr} model download ${cfg.model}" ];
      TimeoutStartSec = "30min";
    };

    smind.desktop.gnome.custom-keybindings = lib.mkIf cfg.gnome.enable [ shortcut ];
    smind.desktop.gnome.extensions.extraPackages = lib.optional (
      cfg.gnome.enable && cfg.gnome.waveform.enable
    ) waveformExtension;
    programs.dconf.profiles.${config.smind.desktop.gnome.dconf.profile}.databases =
      lib.mkIf cfg.gnome.enable
        [
          {
            settings = {
              "org/gnome/desktop/interface".toolkit-accessibility = true;
            }
            // lib.optionalAttrs (!config.smind.desktop.gnome.minimal-hotkeys) {
              "org/gnome/settings-daemon/plugins/media-keys".custom-keybindings = [ "/${shortcutPath}/" ];
              ${shortcutPath} = {
                inherit (shortcut) binding command;
                name = shortcut.label;
              };
            };
          }
        ];
  };
}
