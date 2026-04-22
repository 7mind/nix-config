{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.hoymiles-mqtt;
  endpointType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Short name for this DTU endpoint (used in logs).";
      };
      host = lib.mkOption {
        type = lib.types.str;
        description = "IP address or hostname of the DTU / HMS-W inverter.";
      };
      staleMode = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          When true, N consecutive failed polls (see `staleThreshold`) flip
          this DTU into "stale mode" instead of marking its sensors
          Unavailable. Active-power sensors are forced to 0 and energy totals
          keep their last-known value; everything else goes Unavailable. A
          per-inverter `Stale` binary_sensor reflects the mode. Intended for
          DTUs that sleep with the inverter (e.g. HMS-800W-2T's embedded DTU
          drops WiFi at night).
        '';
      };
      holdDailyEnergy = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          When true, each port's `energy_daily` is clamped to its running
          per-day maximum. The held table resets at local midnight, so a
          legitimate fresh 0 at the start of the next day flows through.
          Intended for DTUs that stay online but zero their daily counter
          after sundown (e.g. DTU-WLite-S stick), which HA would otherwise
          interpret as a total_increasing counter reset.
        '';
      };
    };
  };
in
{
  options = {
    smind.services.hoymiles-mqtt = {
      enable = lib.mkEnableOption "Hoymiles → MQTT bridge";

      endpoints = lib.mkOption {
        type = lib.types.listOf endpointType;
        description = ''
          One entry per Hoymiles DTU or HMS-W inverter to poll. The bridge
          polls each one independently — failure of one endpoint does not
          affect the others.
        '';
        example = [
          { name = "stick"; host = "192.168.1.10"; }
          { name = "hms800w"; host = "192.168.1.11"; }
        ];
      };

      pollInterval = lib.mkOption {
        type = lib.types.int;
        default = 30;
        description = ''
          Seconds between polls of each DTU. Hoymiles DTU firmware caps the
          useful polling rate at ~30 s; lower values just waste CPU and the
          DTU will return repeated values.
        '';
      };

      staleThreshold = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = ''
          Number of consecutive failed polls required before a stale-mode DTU
          transitions into stale mode. Only applies to endpoints with
          `staleMode = true`.
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

      baseTopic = lib.mkOption {
        type = lib.types.str;
        default = "hoymiles";
        description = "MQTT base topic for state/availability messages.";
      };
      haDiscoveryPrefix = lib.mkOption {
        type = lib.types.str;
        default = "homeassistant";
        description = "Home Assistant MQTT discovery prefix.";
      };

      logLevel = lib.mkOption {
        type = lib.types.enum [ "DEBUG" "INFO" "WARNING" "ERROR" "CRITICAL" ];
        default = "INFO";
        description = "Bridge log level.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = cfg.endpoints != [ ];
      message = "smind.services.hoymiles-mqtt.endpoints must list at least one DTU.";
    }];

    systemd.services.hoymiles-mqtt-bridge = {
      description = "Hoymiles → MQTT bridge";
      after = [ "network-online.target" "mosquitto.service" ];
      wants = [ "network-online.target" "mosquitto.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        HOYMILES_ENDPOINTS = lib.concatMapStringsSep ","
          (e: "${e.name}=${e.host}") cfg.endpoints;
        HOYMILES_STALE_ENDPOINTS = lib.concatMapStringsSep ","
          (e: e.name) (lib.filter (e: e.staleMode) cfg.endpoints);
        HOYMILES_HOLD_DAILY_ENERGY_ENDPOINTS = lib.concatMapStringsSep ","
          (e: e.name) (lib.filter (e: e.holdDailyEnergy) cfg.endpoints);
        HOYMILES_STALE_THRESHOLD = toString cfg.staleThreshold;
        HOYMILES_POLL_INTERVAL = toString cfg.pollInterval;
        MQTT_HOST = cfg.mqttHost;
        MQTT_PORT = toString cfg.mqttPort;
        MQTT_USER = cfg.mqttUser;
        MQTT_BASE_TOPIC = cfg.baseTopic;
        HA_DISCOVERY_PREFIX = cfg.haDiscoveryPrefix;
        LOG_LEVEL = cfg.logLevel;
      };
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 15;
        LoadCredential = [ "mqtt-password:${cfg.mqttPasswordFile}" ];
        ExecStart = pkgs.writeShellScript "hoymiles-mqtt-bridge-start" ''
          MQTT_PASSWORD="$(tr -d '\n' < "$CREDENTIALS_DIRECTORY/mqtt-password")"
          export MQTT_PASSWORD
          exec ${pkgs.hoymiles-mqtt-bridge}/bin/hoymiles-mqtt-bridge
        '';
        DynamicUser = true;

        # Hardening. Bridge needs outbound TCP (DTUs over LAN + MQTT) and its
        # MQTT password credential. Nothing else.
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
