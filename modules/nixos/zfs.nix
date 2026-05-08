{ pkgs, lib, config, cfg-packages, ... }:

{
  options = {
    smind.zfs.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "ZFS, emails, snapshots, udev";
    };

    smind.zfs.email.enable = lib.mkEnableOption "ZFS mailer";
  };

  config = lib.mkMerge [
    # Set unconditionally — even when smind.zfs.enable=false, hosts may
    # still pull in ZFS via boot.supportedFilesystems (e.g. PXE seed
    # systems in private/hosts/vm/pxe/, pavel-fw with btrfs root that
    # still loads zfs initrd helpers, raspi5 image flashing flow). The
    # nixpkgs ZFS module warns at eval time whenever ZFS is detected
    # without an explicit forceImportRoot value, recommending false as
    # the new default in 26.11. mkDefault keeps host-level overrides
    # cheap if any host genuinely needs forceImport=true (rare).
    {
      boot.zfs.forceImportRoot = lib.mkDefault false;
    }

    (lib.mkIf config.smind.zfs.enable {
      assertions = [
        ({
          assertion = !config.smind.zfs.email.enable || config.programs.msmtp.enable;
          message = "msmtp must be configured for zfs mailer to work ( set programs.msmtp.enable=true )";
        })
      ];

      boot = {
        kernelPackages = cfg-packages.linux-kernel;
        supportedFilesystems = [ "zfs" ];
        initrd = { supportedFilesystems = [ "zfs" ]; };
        zfs.removeLinuxDRM = true;
        zfs.package = pkgs.zfs_unstable;
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
    })
  ];
}
