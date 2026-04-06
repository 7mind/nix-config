{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.zwave-js-ui;
in
{
  options = {
    smind.services.zwave-js-ui = {
      enable = lib.mkEnableOption "Z-Wave JS UI service";
      serialPort = lib.mkOption {
        type = lib.types.path;
        default = "/dev/ttyZWave";
        description = "The serial port for the Z-Wave controller.";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "The host to listen on.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 8091;
        description = "The port to listen on.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.zwave-js-ui = {
      enable = true;
      serialPort = cfg.serialPort;
      settings = {
        HOST = cfg.host;
        PORT = toString cfg.port;
      };
    };

    # Open the default port in the firewall
    networking.firewall.allowedTCPPorts = [ cfg.port 3000 ];
  };
}
