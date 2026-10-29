{ lib, pkgs, config, ... }:

let
  cfg = config.smind.nas-autofs;

  cifsOptions = lib.concatStringsSep "," ([
    "credentials=${cfg.credentialsFile}"
    "uid=${toString cfg.uid}"
    "gid=${toString cfg.gid}"
  ] ++ cfg.mountOptions);

  mkMount = share: {
    where = "${cfg.mountPoint}/${share}";
    what = "//${cfg.server}/${share}";
    type = "cifs";
    options = cifsOptions;

    mountConfig = {
      # Bound mount/umount syscalls so a hung NAS can't block sleep.target
      # indefinitely. Default systemd mount timeout is 90s, way too long for
      # the suspend path.
      TimeoutSec = cfg.mountTimeout;
    };

    # Tear down active CIFS mounts before the kernel freezer runs.
    # Without this, a hung CIFS umount parks the kernel autofs worker in
    # uninterruptible sleep inside autofs_wait()/autofs_do_expire_multi(),
    # the freezer times out at 20s, and systemd-suspend aborts with
    # "Failed to put system to sleep. System resumed again: Device or
    # resource busy". Symptom: lid close appears to be ignored.
    unitConfig = {
      Before = [ "sleep.target" ];
      Conflicts = [ "sleep.target" ];
    };
  };

  mkAutomount = share: {
    where = "${cfg.mountPoint}/${share}";
    wantedBy = [ "multi-user.target" ];

    automountConfig = {
      # Idle expire timeout — replaces autofs --timeout=60.
      TimeoutIdleSec = cfg.idleTimeout;
    };

    # Note: no sleep.target conflict on the .automount unit. The kernel
    # autofs hook itself is harmless across suspend; only the actual .mount
    # needs to be torn down. After resume, the next access reactivates the
    # .mount unit naturally.
  };
in
{
  options = {
    smind.nas-autofs.enable = lib.mkEnableOption "systemd automount units for NAS shares";

    smind.nas-autofs.server = lib.mkOption {
      type = lib.types.str;
      description = "NAS server hostname or IP";
    };

    smind.nas-autofs.shares = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Share names to automount below mountPoint";
    };
    smind.nas-autofs.credentialsFile = lib.mkOption {
      type = lib.types.path;
      description = "Runtime CIFS credentials file";
    };
    smind.nas-autofs.uid = lib.mkOption {
      type = lib.types.ints.unsigned;
      description = "Owner UID for mounted files";
    };
    smind.nas-autofs.gid = lib.mkOption {
      type = lib.types.ints.unsigned;
      description = "Owner GID for mounted files";
    };
    smind.nas-autofs.mountOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "iocharset=utf8" "file_mode=0644" "dir_mode=0755" "soft" "echo_interval=2" "nofail" ];
      description = "Additional CIFS mount options";
    };
    smind.nas-autofs.mountTimeout = lib.mkOption {
      type = lib.types.str;
      default = "10s";
      description = "Timeout for mount and unmount operations";
    };
    smind.nas-autofs.idleTimeout = lib.mkOption {
      type = lib.types.str;
      default = "60";
      description = "Automount idle expiration timeout";
    };

    smind.nas-autofs.mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/nas";
      description = "Base mount point for NAS shares";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.cifs-utils ];

    systemd.mounts = map mkMount cfg.shares;
    systemd.automounts = map mkAutomount cfg.shares;
  };
}
