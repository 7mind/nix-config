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
    };
  };

  config = lib.mkIf cfg.enable {
    services.mosquitto = {
      enable = true;
      listeners = [
        {
          port = cfg.port;
          settings.allow_anonymous = true;
          acl = [ "topic readwrite #" ];
        }
      ];
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
