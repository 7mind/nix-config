{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.zwave-js-ui;
  mosquittoCfg = config.smind.services.mosquitto;

  mqttSettings = {
    host = "mqtt://localhost:${toString mosquittoCfg.port}";
    port = mosquittoCfg.port;
    disabled = false;
    prefix = "zwave";
    name = "zwave-js-ui";
    qos = 1;
    retain = true;
    clean = true;
    reconnectPeriod = 3000;
    store = false;
    allowSelfsigned = false;
    auth = true;
    username = mosquittoCfg.user;
  };

  mqttSettingsJson = builtins.toJSON mqttSettings;
  storeDir = "/var/lib/zwave-js-ui";
in
{
  options = {
    smind.services.zwave-js-ui = {
      enable = lib.mkEnableOption "Z-Wave JS UI service";
      serialPort = lib.mkOption {
        type = lib.types.path;
        default = "/dev/ttyZWave";
        description = "The serial port for the Z-Wave controller.";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "The host to listen on.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 8091;
        description = "The port to listen on.";
      };
      mqtt.enable = lib.mkEnableOption "MQTT integration with Mosquitto";
    };
  };

  config = lib.mkIf cfg.enable {
    services.zwave-js-ui = {
      enable = true;
      serialPort = cfg.serialPort;
      settings = {
        HOST = cfg.host;
        PORT = toString cfg.port;
      };
    };

    systemd.services.zwave-js-ui = lib.mkIf cfg.mqtt.enable {
      serviceConfig = {
        BindReadOnlyPaths = [ mosquittoCfg.passwordFile ];
      };
      preStart = ''
        SETTINGS="${storeDir}/settings.json"
        MQTT_PASSWORD="$(cat ${mosquittoCfg.passwordFile})"
        if [ -f "$SETTINGS" ]; then
          ${lib.getExe pkgs.jq} --argjson mqtt '${mqttSettingsJson}' --arg pw "$MQTT_PASSWORD" '.mqtt = ($mqtt + {password: $pw})' "$SETTINGS" > "$SETTINGS.tmp"
          mv "$SETTINGS.tmp" "$SETTINGS"
        else
          echo '${mqttSettingsJson}' | ${lib.getExe pkgs.jq} --arg pw "$MQTT_PASSWORD" '{mqtt: (. + {password: $pw})}' > "$SETTINGS"
        fi
      '';
    };

    networking.firewall.allowedTCPPorts = [ cfg.port 3000 ];
  };
}
