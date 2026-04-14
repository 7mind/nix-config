{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.smfc;

  mkZoneOptions = {
    enabled = lib.mkOption {
      type = lib.types.bool;
      description = "Enable fan speed control for this zone.";
    };
    ipmi_zone = lib.mkOption {
      type = lib.types.listOf lib.types.ints.unsigned;
      description = "IPMI fan zone indices to control.";
    };
    temp_calc = lib.mkOption {
      type = lib.types.enum [ 0 1 2 ];
      default = 1;
      description = "Temperature calculation: 0=minimum, 1=average, 2=maximum.";
    };
    steps = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Number of fan speed steps.";
    };
    sensitivity = lib.mkOption {
      type = lib.types.number;
      description = "Degrees C change before the controller reacts.";
    };
    polling = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Temperature polling interval in seconds.";
    };
    min_temp = lib.mkOption {
      type = lib.types.number;
      description = "Minimum temperature for fan curve (C).";
    };
    max_temp = lib.mkOption {
      type = lib.types.number;
      description = "Maximum temperature for fan curve (C).";
    };
    min_level = lib.mkOption {
      type = lib.types.ints.between 0 100;
      description = "Minimum fan speed (%).";
    };
    max_level = lib.mkOption {
      type = lib.types.ints.between 0 100;
      description = "Maximum fan speed (%).";
    };
    smoothing = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Moving average window size for temperature readings (1=disabled).";
    };
  };

  mkValueString = v:
    if v == true then "1"
    else if v == false then "0"
    else if lib.isList v then lib.concatMapStringsSep "," toString v
    else lib.generators.mkValueStringDefault { } v;

  toINI = lib.generators.toINI {
    mkKeyValue = lib.generators.mkKeyValueDefault { inherit mkValueString; } "=";
  };

  configFile = toINI ({
    Ipmi = {
      command = "${pkgs.ipmitool}/bin/ipmitool";
    } // lib.optionalAttrs (cfg.ipmi.fan_mode_delay != null) {
      inherit (cfg.ipmi) fan_mode_delay;
    } // lib.optionalAttrs (cfg.ipmi.fan_level_delay != null) {
      inherit (cfg.ipmi) fan_level_delay;
    };
    CPU = cfg.zones.cpu;
    HD = cfg.zones.hd // {
      smartctl_path = "${pkgs.smartmontools}/bin/smartctl";
    };
  } // lib.optionalAttrs (cfg.zones.nvme != null) {
    NVME = cfg.zones.nvme;
  } // lib.optionalAttrs (cfg.zones.gpu != null) {
    GPU = cfg.zones.gpu;
  } // lib.optionalAttrs (cfg.zones.const != null) {
    CONST = cfg.zones.const;
  });

  logLevels = { none = 0; error = 1; config = 2; info = 3; debug = 4; };
  logOutputs = { stdout = 0; stderr = 1; syslog = 2; };
in
{
  options.smind.services.smfc = {
    enable = lib.mkEnableOption "Supermicro fan control daemon (smfc)";

    logLevel = lib.mkOption {
      type = lib.types.enum [ "none" "error" "config" "info" "debug" ];
      default = "info";
      description = "Log verbosity level.";
    };

    logOutput = lib.mkOption {
      type = lib.types.enum [ "stdout" "stderr" "syslog" ];
      default = "syslog";
      description = "Log output destination.";
    };

    ipmi = {
      fan_mode_delay = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Delay after setting fan mode (seconds). Default upstream: 10.";
      };
      fan_level_delay = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Delay after setting fan level (seconds). Default upstream: 2.";
      };
    };

    zones = {
      cpu = lib.mkOption {
        type = lib.types.submodule { options = mkZoneOptions; };
        description = "CPU fan zone configuration.";
      };

      hd = lib.mkOption {
        type = lib.types.submodule {
          options = mkZoneOptions // {
            hd_names = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Drive paths in /dev/disk/by-id/ form.";
            };
            standby_guard_enabled = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Standby guard for RAID arrays.";
            };
            standby_hd_limit = lib.mkOption {
              type = lib.types.int;
              default = 1;
              description = "Number of drives in STANDBY before forcing the array to standby.";
            };
          };
        };
        description = "Hard drive fan zone configuration.";
      };

      nvme = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = mkZoneOptions // {
            nvme_names = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "NVMe device paths.";
            };
          };
        });
        default = null;
        description = "NVMe fan zone configuration.";
      };

      gpu = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = mkZoneOptions // {
            gpu_device_ids = lib.mkOption {
              type = lib.types.listOf lib.types.ints.unsigned;
              default = [ 0 ];
              description = "GPU device indices in nvidia-smi output.";
            };
          };
        });
        default = null;
        description = "GPU fan zone configuration.";
      };

      const = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            enabled = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Enable constant fan controller.";
            };
            ipmi_zone = lib.mkOption {
              type = lib.types.listOf lib.types.ints.unsigned;
              description = "IPMI fan zone indices.";
            };
            level = lib.mkOption {
              type = lib.types.ints.between 0 100;
              description = "Constant fan speed level (%).";
            };
            polling = lib.mkOption {
              type = lib.types.ints.positive;
              default = 30;
              description = "Polling interval in seconds.";
            };
          };
        });
        default = null;
        description = "Constant fan speed zone configuration.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."smfc/smfc.conf".text = configFile;

    systemd.services.smfc = {
      description = "Supermicro Fan Control Daemon";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.smfc}/bin/smfc"
          "-l ${toString logLevels.${cfg.logLevel}}"
          "-o ${toString logOutputs.${cfg.logOutput}}"
          "-c /etc/smfc/smfc.conf"
        ];
        Restart = "on-failure";
        RestartSec = 10;
      };
    };
  };
}
