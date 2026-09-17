{ config, lib, pkgs, ... }:

let
  cfg = config.smind.power-management.suspend-quirks;
  pmCfg = config.smind.power-management;
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
  };

  # GNOME suspend loop fix is now applied via overlay patch (gnome-settings-daemon MR !462)
  # See: https://gitlab.gnome.org/GNOME/gnome-settings-daemon/-/merge_requests/462
  # See: https://gitlab.gnome.org/GNOME/gnome-settings-daemon/-/issues/903

  config = lib.mkIf cfg.enable {
    # Workaround: Disable systemd 256+ user session freezing during sleep
    systemd.services.systemd-suspend.environment.SYSTEMD_SLEEP_FREEZE_USER_SESSIONS =
      lib.mkIf (pmCfg.suspend.enable && cfg.disableFreezeUserSessions) "false";
    systemd.services.systemd-hibernate.environment.SYSTEMD_SLEEP_FREEZE_USER_SESSIONS =
      lib.mkIf (pmCfg.hibernate.enable && cfg.disableFreezeUserSessions) "false";
    systemd.services.systemd-hybrid-sleep.environment.SYSTEMD_SLEEP_FREEZE_USER_SESSIONS =
      lib.mkIf (pmCfg.hibernate.enable && cfg.disableFreezeUserSessions) "false";
    systemd.services.systemd-suspend-then-hibernate.environment.SYSTEMD_SLEEP_FREEZE_USER_SESSIONS =
      lib.mkIf (pmCfg.hibernate.enable && cfg.disableFreezeUserSessions) "false";
  };
}
