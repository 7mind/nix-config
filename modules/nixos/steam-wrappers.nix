{ config, lib, wrapAppWithNetnsSlice, ... }:

let
  cfg = config.smind.gaming.steam.wrappers;
  sliceName =
    if cfg.sliceName == null
    then null
    else "${cfg.sliceName}.slice";

  wrappedSteam = wrapAppWithNetnsSlice {
    pkg = config.smind.gaming.steam.package;
    name = "steam";
    binName = "steam";
    slice = sliceName;
    netns = cfg.steam.netns;
  };

  wrappedHeroic = wrapAppWithNetnsSlice {
    pkg = config.smind.gaming.steam.heroic.package;
    name = "heroic";
    binName = "heroic";
    slice = sliceName;
    netns = cfg.heroic.netns;
  };
in
{
  options.smind.gaming.steam.wrappers = {
    enable = lib.mkEnableOption "Steam and Heroic wrappers with netns and slice support";

    sliceName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "User systemd slice name without .slice suffix (null disables slice scoping)";
    };

    cpuQuota = lib.mkOption {
      type = lib.types.str;
      default = "100%";
      description = "CPU quota for wrapper slice";
    };

    cpuWeight = lib.mkOption {
      type = lib.types.int;
      default = 50;
      description = "CPU weight for wrapper slice";
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "4G";
      description = "Memory limit for wrapper slice";
    };

    steam.netns = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Network namespace for Steam wrapper";
    };

    heroic.netns = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Network namespace for Heroic wrapper";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = config.smind.gaming.steam.enable;
            message = "smind.gaming.steam.wrappers.enable requires smind.gaming.steam.enable";
          }
          {
            assertion =
              cfg.sliceName != null || cfg.steam.netns != null || cfg.heroic.netns != null;
            message = "smind.gaming.steam.wrappers.enable requires at least one of sliceName, steam.netns, or heroic.netns";
          }
        ];

        smind.gaming.steam.wrappedPackage = wrappedSteam;
        smind.gaming.steam.heroic.wrappedPackage = wrappedHeroic;

        systemd.user.slices = lib.mkIf (cfg.sliceName != null) {
          ${cfg.sliceName} = {
            description = "Slice for wrapped gaming launchers";
            sliceConfig = {
              CPUQuota = cfg.cpuQuota;
              CPUWeight = cfg.cpuWeight;
              MemoryMax = cfg.memoryMax;
            };
          };
        };
      }
    ]
  );
}
