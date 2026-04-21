{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.saic-mqtt;
in
{
  options = {
    smind.services.saic-mqtt = {
      enable = lib.mkEnableOption "SAIC (MG iSMART) to MQTT gateway";

      saicUser = lib.mkOption {
        type = lib.types.str;
        description = "SAIC (iSMART) account username (usually an email).";
      };
      saicPasswordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to file containing the SAIC account password.";
      };
      saicRestUri = lib.mkOption {
        type = lib.types.str;
        default = "https://gateway-mg-eu.soimt.com/api.app/v1/";
        description = "SAIC API endpoint URL.";
      };
      saicRegion = lib.mkOption {
        type = lib.types.str;
        default = "eu";
        description = "SAIC API region.";
      };
      saicTenantId = lib.mkOption {
        type = lib.types.str;
        default = "459771";
        description = "SAIC API tenant ID.";
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
      mqttTopicPrefix = lib.mkOption {
        type = lib.types.str;
        default = "saic";
        description = "MQTT topic prefix.";
      };

      haDiscoveryEnabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Home Assistant MQTT discovery.";
      };
      haDiscoveryPrefix = lib.mkOption {
        type = lib.types.str;
        default = "homeassistant";
        description = "Home Assistant MQTT discovery prefix.";
      };

      logLevel = lib.mkOption {
        type = lib.types.str;
        default = "INFO";
        description = "Log level (INFO, DEBUG, WARNING, ERROR, CRITICAL).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.saic-mqtt-gateway = {
      description = "SAIC (MG iSMART) to MQTT gateway";
      after = [ "network-online.target" "mosquitto.service" ];
      wants = [ "network-online.target" "mosquitto.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        SAIC_USER = cfg.saicUser;
        SAIC_REST_URI = cfg.saicRestUri;
        SAIC_REGION = cfg.saicRegion;
        SAIC_TENANT_ID = cfg.saicTenantId;
        MQTT_URI = "tcp://${cfg.mqttHost}:${toString cfg.mqttPort}";
        MQTT_USER = cfg.mqttUser;
        MQTT_TOPIC = cfg.mqttTopicPrefix;
        HA_DISCOVERY_ENABLED = if cfg.haDiscoveryEnabled then "True" else "False";
        HA_DISCOVERY_PREFIX = cfg.haDiscoveryPrefix;
        LOG_LEVEL = cfg.logLevel;
      };
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 15;
        LoadCredential = [
          "saic-password:${cfg.saicPasswordFile}"
          "mqtt-password:${cfg.mqttPasswordFile}"
        ];
        # Passwords come from credential files; strip trailing newlines and
        # export as env vars before exec'ing the gateway.
        ExecStart = pkgs.writeShellScript "saic-mqtt-gateway-start" ''
          SAIC_PASSWORD="$(tr -d '\n' < "$CREDENTIALS_DIRECTORY/saic-password")"
          MQTT_PASSWORD="$(tr -d '\n' < "$CREDENTIALS_DIRECTORY/mqtt-password")"
          export SAIC_PASSWORD MQTT_PASSWORD
          exec ${pkgs.saic-mqtt-gateway}/bin/saic-mqtt-gateway
        '';
        DynamicUser = true;

        # Hardening. This is 3rd-party Python with a large transitive dep
        # tree; all it actually needs is outbound TCP and its credentials.
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
