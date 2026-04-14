{ config, lib, pkgs, cfg-flakes, ... }:

let
  cfg = config.smind.services.spc-mqtt;
  spcMqtt = cfg-flakes.mqtt-spc.packages.${pkgs.system}.default;
in
{
  options = {
    smind.services.spc-mqtt = {
      enable = lib.mkEnableOption "SPC alarm panel to MQTT bridge";
      spcUrl = lib.mkOption {
        type = lib.types.str;
        description = "SPC panel base URL (e.g. http://panel-ip).";
      };
      spcCredentialsFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to the JSON file with SPC panel login and password
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
      pollInterval = lib.mkOption {
        type = lib.types.int;
        default = 5;
        description = "Polling interval in seconds.";
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
          "spc-credentials:${cfg.spcCredentialsFile}"
          "mqtt-password:${cfg.mqttPasswordFile}"
        ];
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
          "--spc-url ${cfg.spcUrl}"
          "--spc-creds \${CREDENTIALS_DIRECTORY}/spc-credentials"
          "--mqtt-host ${cfg.mqttHost}"
          "--mqtt-port ${toString cfg.mqttPort}"
          "--mqtt-creds \${RUNTIME_DIRECTORY}/mqtt-creds.json"
          "--topic-prefix ${cfg.topicPrefix}"
          "--discovery-prefix ${cfg.discoveryPrefix}"
          "--poll-interval ${toString cfg.pollInterval}"
        ] ++ map (zc: "--zone-class ${zc}") cfg.zoneClasses);
        DynamicUser = true;
      };
    };
  };
}
