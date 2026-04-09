{ config, lib, pkgs, cfg-flakes, ... }:

let
  cfg = config.smind.services.qendercore;
  rustAdapter = cfg-flakes.qendercore-adapter.packages.${pkgs.system}.qendercore-mqtt-adapter;
in
{
  options = {
    smind.services.qendercore = {
      enable = lib.mkEnableOption "Qendercore MQTT adapter";
      credentialsFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to the JSON file with Qendercore login and password
          (`{"login": "...", "password": "..."}`).
        '';
      };
      mqttHost = lib.mkOption {
        type = lib.types.str;
        description = "MQTT broker hostname.";
      };
      mqttPort = lib.mkOption {
        type = lib.types.port;
        default = 1883;
        description = "MQTT broker port.";
      };
      mqttUser = lib.mkOption {
        type = lib.types.str;
        default = "mqtt";
        description = "MQTT username.";
      };
      mqttPasswordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to the file containing the MQTT password.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.qendercore-mqtt = {
      description = "Qendercore MQTT adapter";
      after = [ "network-online.target" "mosquitto.service" ];
      wants = [ "network-online.target" "mosquitto.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 5;
        LoadCredential = [
          "qcore-credentials:${cfg.credentialsFile}"
          "mqtt-password:${cfg.mqttPasswordFile}"
        ];
        ExecStart = lib.concatStringsSep " " [
          "${rustAdapter}/bin/qendercore-mqtt-adapter"
          "--qc-credentials-file \${CREDENTIALS_DIRECTORY}/qcore-credentials"
          "--cache-dir \${STATE_DIRECTORY}"
          "--mqtt-host ${cfg.mqttHost}"
          "--mqtt-port ${toString cfg.mqttPort}"
          "--mqtt-user ${cfg.mqttUser}"
          "--mqtt-password-file \${CREDENTIALS_DIRECTORY}/mqtt-password"
        ];
        StateDirectory = "qendercore-mqtt";
        StateDirectoryMode = "0700";
        DynamicUser = true;
      };
    };
  };
}
