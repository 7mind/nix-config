{ config, lib, pkgs, cfg-flakes, ... }:

let
  cfg = config.smind.services.spc-mqtt;
  spcMqtt = cfg-flakes.mqtt-spc.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  options = {
    smind.services.spc-mqtt = {
      enable = lib.mkEnableOption "SPC alarm panel to MQTT bridge (EDP receiver)";
      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "Address the EDP receiver listens on; the panel connects to it.";
      };
      listenPort = lib.mkOption {
        type = lib.types.port;
        default = 50000;
        description = "TCP port the EDP receiver listens on (panel's Receiver IP Port).";
      };
      receiverId = lib.mkOption {
        type = lib.types.ints.between 1 999997;
        description = "EDP receiver ID, as configured for this receiver on the panel.";
      };
      edpKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          File with the receiver's 32-hex-digit EDP AES key, matching the
          panel's receiver encryption key. Null for unencrypted EDP.
        '';
      };
      firewallInterface = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Interface on which to open listenPort for the panel's connection.";
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
      topicPrefix = lib.mkOption {
        type = lib.types.str;
        default = "spc";
        description = "MQTT topic prefix.";
      };
      discoveryPrefix = lib.mkOption {
        type = lib.types.str;
        default = "homeassistant";
        description = "Home Assistant MQTT discovery prefix.";
      };
      refreshInterval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Seconds between full area/zone/alert re-reads (covers missed events).";
      };
      idleTimeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 120;
        description = "Drop the panel connection after this many seconds without traffic.";
      };
      unsetName = lib.mkOption {
        type = lib.types.str;
        default = "Unset";
        description = "Label for the unset mode in the area mode select.";
      };
      partSetAName = lib.mkOption {
        type = lib.types.str;
        default = "Part Set A";
        description = "Panel's name for part set A, shown in the area mode select.";
      };
      partSetBName = lib.mkOption {
        type = lib.types.str;
        default = "Part Set B";
        description = "Panel's name for part set B, shown in the area mode select.";
      };
      fullSetName = lib.mkOption {
        type = lib.types.str;
        default = "Fullset";
        description = "Label for the full set mode in the area mode select.";
      };
      zoneClasses = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Zone device class overrides in "ID=CLASS" format
          (e.g. ["1=door" "2=motion"]).
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.interfaces = lib.mkIf (cfg.firewallInterface != null) {
      ${cfg.firewallInterface}.allowedTCPPorts = [ cfg.listenPort ];
    };

    systemd.services.spc-mqtt = {
      description = "SPC alarm panel to MQTT bridge";
      after = [ "network-online.target" "mosquitto.service" ];
      wants = [ "network-online.target" "mosquitto.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 5;
        LoadCredential = [
          "mqtt-password:${cfg.mqttPasswordFile}"
        ] ++ lib.optional (cfg.edpKeyFile != null) "edp-key:${cfg.edpKeyFile}";
        RuntimeDirectory = "spc-mqtt";
        RuntimeDirectoryMode = "0700";
        ExecStartPre = let
          jq = "${pkgs.jq}/bin/jq";
        in
          "${pkgs.writeShellScript "spc-mqtt-prepare-mqtt-creds" ''
            ${jq} -n \
              --arg login "${cfg.mqttUser}" \
              --rawfile pass "''${CREDENTIALS_DIRECTORY}/mqtt-password" \
              '{"login": $login, "password": ($pass | rtrimstr("\n"))}' \
              > "''${RUNTIME_DIRECTORY}/mqtt-creds.json"
          ''}";
        ExecStart = lib.concatStringsSep " " ([
          "${spcMqtt}/bin/spc-mqtt"
          "--listen ${cfg.listenAddress}:${toString cfg.listenPort}"
          "--receiver-id ${toString cfg.receiverId}"
          "--refresh-interval ${toString cfg.refreshInterval}"
          "--idle-timeout ${toString cfg.idleTimeout}"
          "--mqtt-host ${cfg.mqttHost}"
          "--mqtt-port ${toString cfg.mqttPort}"
          "--mqtt-creds \${RUNTIME_DIRECTORY}/mqtt-creds.json"
          "--topic-prefix ${cfg.topicPrefix}"
          "--discovery-prefix ${cfg.discoveryPrefix}"
          "--unset-name ${lib.escapeShellArg cfg.unsetName}"
          "--part-set-a-name ${lib.escapeShellArg cfg.partSetAName}"
          "--part-set-b-name ${lib.escapeShellArg cfg.partSetBName}"
          "--full-set-name ${lib.escapeShellArg cfg.fullSetName}"
        ] ++ lib.optional (cfg.edpKeyFile != null) "--edp-key-file \${CREDENTIALS_DIRECTORY}/edp-key"
          ++ map (zc: "--zone-class ${zc}") cfg.zoneClasses);
        DynamicUser = true;

        # Hardening. All this service needs is a listening TCP socket for the
        # panel, outbound TCP to MQTT, its credentials, and its RuntimeDirectory.
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
