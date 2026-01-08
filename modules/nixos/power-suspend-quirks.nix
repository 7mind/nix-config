{ config, lib, pkgs, ... }:

let
  cfg = config.smind.power-management.suspend-quirks;
in
{
  options.smind.power-management.suspend-quirks = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.isLaptop;
      description = "Enable suspend/hibernate quirks and workarounds";
    };

    disableFreezeUserSessions = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Disable systemd 256+ user session freezing during sleep.
        This feature doesn't work reliably with NVIDIA/AMD drivers and causes suspend failures.
        See: https://github.com/NixOS/nixpkgs/issues/371058
      '';
    };

    suspend.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = "Enable suspend support";
    };

    hibernate.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable && !config.smind.zfs.enable;
      description = "Enable hibernate and hybrid-sleep support (disabled by default with ZFS)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Enable sleep targets
    systemd.targets.sleep.enable = lib.mkIf (cfg.suspend.enable || cfg.hibernate.enable) true;
    systemd.targets.suspend.enable = lib.mkIf cfg.suspend.enable true;
    systemd.targets.hibernate.enable = lib.mkIf cfg.hibernate.enable true;
    systemd.targets.hybrid-sleep.enable = lib.mkIf cfg.hibernate.enable true;

    # Workaround: Disable systemd 256+ user session freezing during sleep
    systemd.services.systemd-suspend.environment.SYSTEMD_SLEEP_FREEZE_USER_SESSIONS =
      lib.mkIf (cfg.suspend.enable && cfg.disableFreezeUserSessions) "false";
    systemd.services.systemd-hibernate.environment.SYSTEMD_SLEEP_FREEZE_USER_SESSIONS =
      lib.mkIf (cfg.hibernate.enable && cfg.disableFreezeUserSessions) "false";
    systemd.services.systemd-hybrid-sleep.environment.SYSTEMD_SLEEP_FREEZE_USER_SESSIONS =
      lib.mkIf (cfg.hibernate.enable && cfg.disableFreezeUserSessions) "false";
    systemd.services.systemd-suspend-then-hibernate.environment.SYSTEMD_SLEEP_FREEZE_USER_SESSIONS =
      lib.mkIf (cfg.hibernate.enable && cfg.disableFreezeUserSessions) "false";
  };
}
