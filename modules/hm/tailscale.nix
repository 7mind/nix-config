{ config, lib, pkgs, osConfig, ... }:

let
  cfg = config.smind.hm.tailscale;
  tailscaleEnabled = osConfig.smind.net.tailscale.enable;
in
{
  options.smind.hm.tailscale = {
    systray.enable = lib.mkOption {
      type = lib.types.bool;
      default = tailscaleEnabled;
      description = "Enable Tailscale systray (defaults to true if smind.net.tailscale.enable is set)";
    };
  };

  config = lib.mkIf cfg.systray.enable {
    systemd.user.services.tailscale-systray = {
      Unit = {
        Description = "Tailscale systray";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.tailscale}/bin/tailscale systray";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
