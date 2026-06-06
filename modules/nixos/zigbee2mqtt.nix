{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.zigbee2mqtt;
  mosquittoCfg = config.smind.services.mosquitto;
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
      adapter = lib.mkOption {
        type = lib.types.str;
        description = "The Zigbee adapter type (e.g. zstack, ember).";
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
        serial.adapter = cfg.adapter;
        frontend = {
          enabled = true;
          host = cfg.host;
          port = cfg.port;
        };
        mqtt = {
          server = "mqtt://localhost:${toString mosquittoCfg.port}";
          user = mosquittoCfg.user;
          password = "!secret mqtt_password";
        };
        homeassistant.enabled = true;
        homeassistant.experimental_event_entities = true;
        permit_join = false;
        # Availability tracking: z2m pings devices and publishes online/offline
        # status, to detect mains-powered devices dropping off the network.
        availability = {
          enabled = true;
          active.timeout = 10;   # minutes — mains-powered routers
          passive.timeout = 1500;  # minutes — battery-powered end devices
        };
        advanced.log_output = [ "console" "syslog" ];
        advanced.channel = 15;
        advanced.last_seen = "ISO_8601";
        # Silence per-publish MQTT spam (one INFO line per device update);
        # other namespaces stay at INFO so join/leave and startup stay visible.
        advanced.log_namespaced_levels = {
          "z2m:mqtt" = "warning";
        };
      };
    };

    systemd.services.zigbee2mqtt.preStart = ''
      echo "mqtt_password: $(cat ${mosquittoCfg.passwordFile})" > /var/lib/zigbee2mqtt/secret.yaml
    '';

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
