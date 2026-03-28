{ config, lib, cfg-meta, outerConfig, ... }:

let
  cfg = config.smind.hm.three-finger-drag;
  jsonFormat = lib.generators.toJSON { };
in
{
  options.smind.hm.three-finger-drag = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg-meta.isLinux && (outerConfig.smind.three-finger-drag.enable or false);
      description = "Manage linux-3-finger-drag config file";
    };

    acceleration = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = "Movement speed multiplier";
    };

    dragEndDelay = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "Milliseconds to persist mouse-hold after fingers lift";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "off" "error" "warn" "info" "debug" "trace" ];
      default = "info";
      description = "Log verbosity level";
    };

    responseTime = lib.mkOption {
      type = lib.types.int;
      default = 50; # increase default 5 10x due to battery drain
      description = "Event polling interval in milliseconds";
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile."linux-3-finger-drag/3fd-config.json".text = jsonFormat {
      inherit (cfg) acceleration dragEndDelay logLevel responseTime;
    };
  };
}
