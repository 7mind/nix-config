{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.matter-mqtt-bridge;
in
{
  options = {
    smind.services.matter-mqtt-bridge = {
      enable = lib.mkEnableOption "Matter → MQTT bridge";

      matterUrl = lib.mkOption {
        type = lib.types.str;
        default = "ws://localhost:5580/ws";
        description = "WebSocket URL of the python-matter-server.";
      };

      mqttHost = lib.mkOption {
        type = lib.types.str;
        default = "localhost";
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
        description = "Path to a file containing the MQTT password.";
      };

      baseTopic = lib.mkOption {
        type = lib.types.str;
        default = "matter";
        description = "MQTT topic prefix for state messages.";
      };

      logLevel = lib.mkOption {
        type = lib.types.enum [ "DEBUG" "INFO" "WARNING" "ERROR" "CRITICAL" ];
        default = "INFO";
        description = "Bridge log level.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.matter-mqtt-bridge = {
      description = "Matter → MQTT bridge";
      after = [ "network-online.target" "mosquitto.service" "matter-server.service" ];
      wants = [ "network-online.target" "mosquitto.service" "matter-server.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        MATTER_URL = cfg.matterUrl;
        MQTT_HOST = cfg.mqttHost;
        MQTT_PORT = toString cfg.mqttPort;
        MQTT_USER = cfg.mqttUser;
        BASE_TOPIC = cfg.baseTopic;
        LOG_LEVEL = cfg.logLevel;
      };
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 15;
        LoadCredential = [ "mqtt-password:${cfg.mqttPasswordFile}" ];
        ExecStart = pkgs.writeShellScript "matter-mqtt-bridge-start" ''
          MQTT_PASSWORD="$(tr -d '\n' < "$CREDENTIALS_DIRECTORY/mqtt-password")"
          export MQTT_PASSWORD
          exec ${pkgs.matter-mqtt-bridge}/bin/matter-mqtt-bridge
        '';
        DynamicUser = true;

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateUsers = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
        UMask = "0077";
      };
    };
  };
}
