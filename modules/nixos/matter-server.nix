{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.matter-server;
in
{
  options = {
    smind.services.matter-server = {
      enable = lib.mkEnableOption "Matter Server (python-matter-server)";
      port = lib.mkOption {
        type = lib.types.port;
        default = 5580;
        description = "TCP port for the WebSocket API consumed by Home Assistant.";
      };
      logLevel = lib.mkOption {
        type = lib.types.enum [ "critical" "error" "warning" "info" "debug" ];
        default = "info";
        description = "Verbosity of matter-server logs.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.matter-server = {
      enable = true;
      port = cfg.port;
      openFirewall = true;
      logLevel = cfg.logLevel;
    };

    # UDP 5540 = Matter operational traffic on the fabric.
    # UDP 5353 = mDNS, used to discover commissioned devices.
    networking.firewall.allowedUDPPorts = [ 5540 5353 ];
  };
}
