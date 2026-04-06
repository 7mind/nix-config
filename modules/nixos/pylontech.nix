{ config, lib, pkgs, cfg-flakes, cfg-meta, ... }:

let
  cfg = config.smind.services.pylontech;
in
{
  options = {
    smind.services.pylontech = {
      enable = lib.mkEnableOption "Pylontech battery poller";
      rs485Host = lib.mkOption {
        type = lib.types.str;
        description = "Hostname of the RS485 gateway.";
      };
      pollInterval = lib.mkOption {
        type = lib.types.int;
        default = 5000;
        description = "Polling interval in milliseconds.";
      };
      mqttHost = lib.mkOption {
        type = lib.types.str;
        description = "MQTT broker hostname.";
      };
      mqttPasswordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to the file containing the MQTT password.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.pylontech-poller = {
      description = "Pylontech Battery Poller";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = ''
          ${cfg-flakes.pylontech.default}/bin/poller ${cfg.rs485Host} \
            --interval ${toString cfg.pollInterval} \
            --mqtt-host ${cfg.mqttHost} \
            --mqtt-password ${cfg.mqttPasswordFile}
        '';
        Restart = "always";
      };
    };
  };
}
