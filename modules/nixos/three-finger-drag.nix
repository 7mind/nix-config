{ config, lib, pkgs, ... }:

let
  cfg = config.smind.three-finger-drag;
in
{
  options.smind.three-finger-drag = {
    enable = lib.mkEnableOption "three-finger trackpad drag (macOS-style)";
  };

  config = lib.mkIf cfg.enable {
    # udev rule to grant access to /dev/uinput for input group
    services.udev.extraRules = ''
      KERNEL=="uinput", GROUP="input", MODE="0660", TAG+="uaccess"
    '';

    # Ensure uinput kernel module is loaded
    boot.kernelModules = [ "uinput" ];

    # User service — runs per-user in graphical session
    systemd.user.services.linux-3-finger-drag = {
      description = "Three-finger drag gestures for Linux";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];

      serviceConfig = {
        Type = "exec";
        ExecStart = lib.getExe pkgs.linux-3-finger-drag;
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
