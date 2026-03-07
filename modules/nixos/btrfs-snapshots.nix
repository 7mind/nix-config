{ config, lib, ... }:

let
  cfg = config.smind.btrfs.snapshots;
  homeFs = config.fileSystems."/home";
in
{
  options.smind.btrfs.snapshots = {
    enable = lib.mkEnableOption "Periodic Btrfs snapshots for home subvolume";

    volumePath = lib.mkOption {
      type = lib.types.str;
      default = "/home";
      description = "Mounted Btrfs volume path that contains the home subvolume (for example `/`).";
    };

    subvolumePath = lib.mkOption {
      type = lib.types.str;
      default = ".";
      description = "Home subvolume path relative to `volumePath` (for example `@home`).";
    };

    snapshotDir = lib.mkOption {
      type = lib.types.str;
      default = "btrbk_snapshots";
      description = "Snapshot directory name inside the source subvolume.";
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "Systemd calendar expression for snapshot runs.";
    };

    snapshotPreserveMin = lib.mkOption {
      type = lib.types.str;
      default = "1d";
      description = "Minimum age guarantee for all snapshots.";
    };

    snapshotPreserve = lib.mkOption {
      type = lib.types.str;
      default = "24h 7d";
      description = "Retention buckets, e.g. 24 hourly and 7 daily snapshots.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = homeFs.fsType == "btrfs";
        message = "smind.btrfs.snapshots requires fileSystems.\"/home\" to be btrfs.";
      }
    ];

    services.btrbk.instances.home = {
      onCalendar = cfg.onCalendar;
      settings = {
        timestamp_format = "long";
        snapshot_preserve_min = cfg.snapshotPreserveMin;
        snapshot_preserve = cfg.snapshotPreserve;
        volume.${cfg.volumePath}.subvolume.${cfg.subvolumePath}.snapshot_dir = cfg.snapshotDir;
      };
    };
  };
}
