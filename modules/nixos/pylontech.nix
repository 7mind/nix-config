{ config, lib, cfg-flakes, ... }:

let
  cfg = config.smind.services.pylontech;
  rustAdapter = cfg-flakes.pylontech.default;
in
{
  options = {
    smind.services.pylontech = {
      enable = lib.mkEnableOption "Pylontech battery poller";
      rs485Host = lib.mkOption {
        type = lib.types.str;
        description = "Hostname of the RS485 gateway.";
      };
      rs485Port = lib.mkOption {
        type = lib.types.port;
        default = 23;
        description = "TCP port of the RS485 gateway.";
      };
      pollInterval = lib.mkOption {
        type = lib.types.int;
        default = 5000;
        description = "Polling interval in milliseconds.";
      };
      managementInterval = lib.mkOption {
        type = lib.types.int;
        default = 30000;
        description = "Management info polling interval in milliseconds.";
      };
      scanStart = lib.mkOption {
        type = lib.types.int;
        default = 2;
        description = "First module address to probe (inclusive).";
      };
      scanEnd = lib.mkOption {
        type = lib.types.int;
        default = 9;
        description = "Last module address to probe (inclusive).";
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
    systemd.services.pylontech-poller = {
      description = "Pylontech Battery Poller";
      after = [ "network-online.target" "mosquitto.service" ];
      wants = [ "network-online.target" "mosquitto.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 5;
        LoadCredential = "mqtt-password:${cfg.mqttPasswordFile}";
        ExecStart = lib.concatStringsSep " " [
          "${rustAdapter}/bin/pylontech-mqtt-adapter"
          "${cfg.rs485Host}"
          "--source-port ${toString cfg.rs485Port}"
          "--interval-millis ${toString cfg.pollInterval}"
          "--management-interval-millis ${toString cfg.managementInterval}"
          "--scan-start ${toString cfg.scanStart}"
          "--scan-end ${toString cfg.scanEnd}"
          "--mqtt-host ${cfg.mqttHost}"
          "--mqtt-port ${toString cfg.mqttPort}"
          "--mqtt-user ${cfg.mqttUser}"
          "--mqtt-password-file \${CREDENTIALS_DIRECTORY}/mqtt-password"
        ];
        DynamicUser = true;

        # Hardening. All this service needs is outbound TCP (RS485 gateway +
        # MQTT) and its credentials.
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
