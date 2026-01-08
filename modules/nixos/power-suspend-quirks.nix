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

    gnomeIdleResetWorkaround = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable GNOME idle reset workaround on resume.
        This workaround resets the GNOME session presence to prevent gsd-power from
        immediately re-suspending after resume due to stale idle timer state.

        This is now DISABLED by default because we apply the upstream fix from
        gnome-settings-daemon MR !462 which properly handles inactive sessions.
        See: https://gitlab.gnome.org/GNOME/gnome-settings-daemon/-/merge_requests/462
        See: https://gitlab.gnome.org/GNOME/gnome-settings-daemon/-/issues/903
        See: https://github.com/NixOS/nixpkgs/issues/336723
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

    # Workaround: Reset GNOME idle state after resume to prevent suspend loop
    # gsd-power doesn't reset its internal idle counter after resume, causing immediate re-suspend
    # Uses system-sleep hook for immediate execution on resume (before gsd-power can react)
    # NOTE: This is now disabled by default because we apply the upstream fix (MR !462)
    # See: https://gitlab.gnome.org/GNOME/gnome-settings-daemon/-/merge_requests/462
    # See: https://github.com/NixOS/nixpkgs/issues/336723
    powerManagement.powerDownCommands = lib.mkIf (config.smind.desktop.gnome.enable && cfg.gnomeIdleResetWorkaround) "";
    powerManagement.resumeCommands = lib.mkIf (config.smind.desktop.gnome.enable && cfg.gnomeIdleResetWorkaround) ''
      # Reset idle hint for all logind sessions immediately on resume
      ${pkgs.systemd}/bin/loginctl list-sessions --no-legend | while read -r session rest; do
        ${pkgs.systemd}/bin/loginctl set-idle-hint "$session" no 2>/dev/null || true
      done

      # Reset GNOME session presence to "available" (0) for all graphical users
      # This signals gnome-session that user is active, resetting gsd-power's idle timer
      for uid in $(${pkgs.systemd}/bin/loginctl list-users --no-legend | ${pkgs.gawk}/bin/awk '{print $1}'); do
        user=$(${pkgs.coreutils}/bin/id -nu "$uid" 2>/dev/null) || continue
        runtime_dir="/run/user/$uid"
        [ -S "$runtime_dir/bus" ] || continue

        ${pkgs.sudo}/bin/sudo -u "$user" \
          DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
          ${pkgs.dbus}/bin/dbus-send --session --type=method_call \
            --dest=org.gnome.SessionManager \
            /org/gnome/SessionManager/Presence \
            org.gnome.SessionManager.Presence.SetStatus \
            uint32:0 2>/dev/null || true
      done
    '';
  };
}
