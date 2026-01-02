{ config, lib, pkgs, ... }:

let
  cfg = config.smind.input-remapper;

  # Generate config.json with autoload settings
  configJson = builtins.toJSON {
    version = "2.2.0";
    autoload = cfg.autoload;
  };
in
{
  options.smind.input-remapper = {
    enable = lib.mkEnableOption "input-remapper for keyboard/mouse remapping";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.input-remapper;
      description = "The input-remapper package to use";
    };

    autoload = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Map of device names to preset names for autoloading";
      example = { "Framework Laptop 16 Keyboard Module - ANSI Keyboard" = "mac-style"; };
    };

    devices = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          presets = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule {
              options = {
                mappings = lib.mkOption {
                  type = lib.types.listOf lib.types.attrs;
                  default = [ ];
                  description = "List of mapping objects";
                };
              };
            });
            default = { };
            description = "Presets for this device";
          };
        };
      });
      default = { };
      description = "Per-device preset configurations";
    };
  };

  config = lib.mkIf cfg.enable {
    # GNOME extension is handled by gnome-extensions.nix
    environment.systemPackages = [ cfg.package ];

    # uinput is required for input-remapper
    boot.kernelModules = [ "uinput" ];
    hardware.uinput.enable = true;

    # System service for input-remapper daemon
    systemd.services.input-remapper = {
      description = "Input Remapper Daemon";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/input-remapper-service";
        Restart = "always";
        RestartSec = 3;
        Nice = -20;
      };
    };

    # Create system-wide config directory and files
    # Note: input-remapper reads from ~/.config/input-remapper-2/ per user
    # For system-wide declarative config, we use /etc and symlink
    environment.etc = let
      deviceConfigs = lib.flatten (lib.mapAttrsToList (deviceName: deviceCfg:
        lib.mapAttrsToList (presetName: presetCfg: {
          name = "input-remapper-2/presets/${deviceName}/${presetName}.json";
          value = { text = builtins.toJSON presetCfg.mappings; mode = "0644"; };
        }) deviceCfg.presets
      ) cfg.devices);
    in lib.listToAttrs (map (x: { name = x.name; value = x.value; }) deviceConfigs) // {
      "input-remapper-2/config.json" = {
        text = configJson;
        mode = "0644";
      };
    };

    # Set XDG_CONFIG_DIRS to include /etc so input-remapper finds the config
    environment.sessionVariables.XDG_CONFIG_DIRS = lib.mkAfter [ "/etc" ];
  };
}
