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
      settings = {
        # Allow large retained messages (z2m bridge/devices can be ~200KB+).
        message_size_limit = 0; # 0 = unlimited (mosquitto default, explicit)
      };
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
