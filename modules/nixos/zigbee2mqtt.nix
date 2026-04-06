{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.zigbee2mqtt;
in
{
  options = {
    smind.services.zigbee2mqtt = {
      enable = lib.mkEnableOption "Zigbee2MQTT service";
      serialPort = lib.mkOption {
        type = lib.types.path;
        default = "/dev/ttyZigbee";
        description = "The serial port for the Zigbee controller.";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "The host to listen on.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        description = "The port for the web frontend.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.zigbee2mqtt = {
      enable = true;
      settings = {
        serial.port = cfg.serialPort;
        frontend = {
          host = cfg.host;
          port = cfg.port;
        };
        mqtt.server = "mqtt://localhost:${toString config.smind.services.mosquitto.port}";
        homeassistant.enabled = true;
        permit_join = false;
      };
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
