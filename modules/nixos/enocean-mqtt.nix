{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.enocean-mqtt;

  deviceType = lib.types.submodule {
    options = {
      address = lib.mkOption {
        type = lib.types.str;
        example = "0x05A1B2C3";
        description = "32-bit EnOcean sensor address (hex), captured during teach-in.";
      };
      rorg = lib.mkOption {
        type = lib.types.str;
        example = "0xA5";
        description = "EEP RORG byte (e.g. 0xA5 for 4BS, 0xD2 for VLD, 0xF6 for RPS).";
      };
      func = lib.mkOption {
        type = lib.types.str;
        example = "0x04";
        description = "EEP FUNC byte.";
      };
      type = lib.mkOption {
        type = lib.types.str;
        example = "0x03";
        description = "EEP TYPE byte.";
      };
      persistent = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Publish readings as MQTT retained messages so subscribers see the
          last known value immediately. Sensible default for periodic sensors
          like temperature/humidity.
        '';
      };
      logLearn = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Forward teach-in telegrams from this device to MQTT and the log.";
      };
      extraSettings = lib.mkOption {
        type = lib.types.attrsOf (lib.types.either lib.types.str lib.types.int);
        default = { };
        description = "Additional INI keys for this sensor section (e.g. publish_rssi, channel).";
      };
    };
  };

  renderValue = v:
    if builtins.isBool v then (if v then "1" else "0")
    else if builtins.isInt v then toString v
    else v;

  renderDevice = name: dev: ''
    [${name}]
    address    = ${dev.address}
    rorg       = ${dev.rorg}
    func       = ${dev.func}
    type       = ${dev.type}
    persistent = ${if dev.persistent then "1" else "0"}
    log_learn  = ${if dev.logLearn then "1" else "0"}
    ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (k: v: "${k} = ${renderValue v}") dev.extraSettings
    )}
  '';

  configTemplate = pkgs.writeText "enoceanmqtt.conf.tmpl" ''
    [CONFIG]
    enocean_port    = ${cfg.enoceanPort}
    log_packets     = ${if cfg.logPackets then "1" else "0"}

    mqtt_host       = ${cfg.mqttHost}
    mqtt_port       = ${toString cfg.mqttPort}
    mqtt_client_id  = ${cfg.mqttClientId}
    mqtt_keepalive  = ${toString cfg.mqttKeepalive}
    mqtt_prefix     = ${cfg.mqttTopicPrefix}
    mqtt_user       = ${cfg.mqttUser}
    mqtt_pwd        = @MQTT_PWD@
    log_learn       = ${if cfg.logLearn then "1" else "0"}

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList renderDevice cfg.devices)}
  '';
in
{
  options.smind.services.enocean-mqtt = {
    enable = lib.mkEnableOption "EnOcean to MQTT bridge (embyt/enocean-mqtt)";

    enoceanPort = lib.mkOption {
      type = lib.types.str;
      default = "/dev/ttyEnOcean";
      description = "Path to the EnOcean USB serial dongle.";
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
      description = "Path to the file containing the MQTT password.";
    };
    mqttTopicPrefix = lib.mkOption {
      type = lib.types.str;
      default = "enocean/";
      description = "MQTT topic prefix; sensor section names are appended.";
    };
    mqttClientId = lib.mkOption {
      type = lib.types.str;
      default = "enocean";
      description = "MQTT client ID. Must be unique per broker.";
    };
    mqttKeepalive = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "MQTT keepalive (seconds). 0 = infinite, but upstream warns it is unreliable.";
    };

    logPackets = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Log every received EnOcean packet (useful while configuring).";
    };
    logLearn = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Globally log teach-in telegrams from any device, including unconfigured
        ones. Keep enabled to capture sensor IDs during pairing.
      '';
    };

    devices = lib.mkOption {
      type = lib.types.attrsOf deviceType;
      default = { };
      example = lib.literalExpression ''
        {
          living_room_th = {
            address = "0x05A1B2C3";
            rorg    = "0xA5";
            func    = "0x04";
            type    = "0x03";
          };
        }
      '';
      description = ''
        Map of MQTT sensor section name → device parameters. The section name
        is appended to mqttTopicPrefix to form the publish topic.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.enocean-mqtt = {
      description = "EnOcean to MQTT bridge";
      after = [ "network-online.target" "mosquitto.service" ];
      wants = [ "network-online.target" "mosquitto.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 15;
        DynamicUser = true;
        SupplementaryGroups = [ "dialout" ];
        RuntimeDirectory = "enocean-mqtt";
        RuntimeDirectoryMode = "0700";
        LoadCredential = [ "mqtt-password:${cfg.mqttPasswordFile}" ];
        ExecStart = pkgs.writeShellScript "enocean-mqtt-start" ''
          set -eu
          PWD_FILE="$CREDENTIALS_DIRECTORY/mqtt-password"
          MQTT_PWD="$(tr -d '\n' < "$PWD_FILE")"
          CONF="$RUNTIME_DIRECTORY/enoceanmqtt.conf"
          ${pkgs.gawk}/bin/awk -v pwd="$MQTT_PWD" '{ gsub(/@MQTT_PWD@/, pwd); print }' \
            ${configTemplate} > "$CONF"
          chmod 0400 "$CONF"
          unset MQTT_PWD
          exec ${pkgs.enocean-mqtt}/bin/enoceanmqtt --logfile=/dev/null "$CONF"
        '';

        # Hardening. Needs the FTDI tty (DeviceAllow + dialout group) and
        # outbound TCP to the MQTT broker; nothing else.
        DeviceAllow = [ "char-ttyUSB rw" ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
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
