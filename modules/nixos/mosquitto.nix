{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.mosquitto;
in
{
  options = {
    smind.services.mosquitto = {
      enable = lib.mkEnableOption "Mosquitto MQTT broker";
      port = lib.mkOption {
        type = lib.types.port;
        default = 1883;
        description = "The port for the MQTT broker.";
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "mqtt";
        description = "MQTT username.";
      };
      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to the file containing the MQTT password.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.mosquitto = {
      enable = true;
      # Persist retained messages and queued QoS>0 messages across
      # broker restarts. Without this, every reboot wipes the broker's
      # retained-message store, and any client that depends on a
      # retained topic existing (e.g. zigbee2mqtt's bridge/devices,
      # bridge/groups, group state echoes) has to wait for the
      # publisher to re-emit. The publisher does so on its own
      # startup, but there's a race window where consumers running
      # right after a reboot find an empty topic.
      #
      # See https://mosquitto.org/man/mosquitto-conf-5.html for
      # `persistence` and `persistence_location`.
      persistence = true;

      listeners = [
        {
          port = cfg.port;
          acl = [ "topic readwrite #" ];
          users.${cfg.user} = {
            passwordFile = cfg.passwordFile;
            acl = [ "readwrite #" ];
          };
        }
      ];
    };

    environment.systemPackages = [ pkgs.mosquitto ];

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
