{ pkgs, lib, config, cfg-packages, ... }:

{
  options = {
    smind.zfs.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "ZFS, emails, snapshots, udev";
    };

    smind.zfs.email.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable ZFS mailer";
    };
  };

  config = lib.mkIf config.smind.zfs.enable {
    assertions = [
      ({
        assertion = !config.smind.zfs.email.enable || config.programs.msmtp.enable;
        message = "msmtp must be configured for zfs mailer to work ( set programs.msmtp.enable=true )";
      })
    ];

    boot = {
      supportedFilesystems = [ "zfs" ];
      initrd = { supportedFilesystems = [ "zfs" ]; };
      zfs.removeLinuxDRM = true;
      # zfs.package = cfg-packages.linux-kernel.zfs_unstable;
    };

    services.zfs = {
      trim.enable = true;
      autoScrub.enable = true;
      autoScrub.interval = "monthly";

      autoSnapshot = {
        # zfs set com.sun:auto-snapshot=true pool/dataset
        enable = true;
        # defaults frequent = 4 (latest 15-minute), 24 hourly, 7 daily, 4 weekly and 12 monthly snapshots.
        daily = 2;
        weekly = 8;
      };
    };

    # this option does not work; will return error
    services.zfs.zed.enableMail = false;
    services.zfs.zed.settings = lib.mkIf config.smind.zfs.email.enable {
      ZED_DEBUG_LOG = "/tmp/zed.debug.log";
      ZED_EMAIL_ADDR = [ config.smind.host.email.to ];
      ZED_EMAIL_PROG = "${pkgs.msmtp}/bin/msmtp";
      ZED_EMAIL_OPTS = "-s @SUBJECT@ -r ${config.smind.host.email.sender} @ADDRESS@";

      ZED_NOTIFY_INTERVAL_SECS = 1;
      ZED_NOTIFY_VERBOSE = true;

      ZED_USE_ENCLOSURE_LEDS = true;
      ZED_SCRUB_AFTER_RESILVER = true;
    };

    # zfs already has its own scheduler. without this my(@Artturin) computer froze for a second when i nix build something.
    services.udev.extraRules = ''
      ACTION=="add|change", KERNEL=="sd[a-z]*[0-9]*|mmcblk[0-9]*p[0-9]*|nvme[0-9]*n[0-9]*p[0-9]*", ENV{ID_FS_TYPE}=="zfs_member", ATTR{../queue/scheduler}="none"
    '';

    /* test script:
       #!/usr/bin/env bash
       set -x
       set -e

       cd /tmp
       dd if=/dev/zero of=sparse_file bs=1 count=0 seek=512M
       zpool create test /tmp/sparse_file
       zpool scrub -w test
       zpool export test
       rm sparse_file
    */
  };
}
