{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.zwave-js-ui;
  mosquittoCfg = config.smind.services.mosquitto;

  mqttSettings = {
    host = "localhost";
    port = mosquittoCfg.port;
    disabled = false;
    prefix = "zwave";
    name = "zwave";
    qos = 1;
    retain = true;
    clean = true;
    reconnectPeriod = 3000;
    store = false;
    allowSelfsigned = false;
    auth = true;
    username = mosquittoCfg.user;
  };

  gatewaySettings = {
    type = 1;
    nodeNames = true;
    hassDiscovery = true;
    discoveryPrefix = "homeassistant";
    retainedDiscovery = true;
    includeNodeInfo = true;
    sendEvents = true;
    publishNodeDetails = true;
    entityTemplate = "%nid";
    ignoreLoc = true;
  };

  mqttSettingsJson = builtins.toJSON mqttSettings;
  gatewaySettingsJson = builtins.toJSON gatewaySettings;
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
      serviceConfig.BindReadOnlyPaths = [
        mosquittoCfg.passwordFile
        "/etc/resolv.conf"
        "/etc/nsswitch.conf"
        "/etc/hosts"
      ];
      preStart = ''
        SETTINGS="${storeDir}/settings.json"
        MQTT_PASSWORD="$(cat ${mosquittoCfg.passwordFile})"
        if [ -f "$SETTINGS" ]; then
          ${lib.getExe pkgs.jq} \
            --argjson mqtt '${mqttSettingsJson}' \
            --argjson gw '${gatewaySettingsJson}' \
            --arg pw "$MQTT_PASSWORD" \
            '.mqtt = ($mqtt + {password: $pw}) | .gateway = $gw' \
            "$SETTINGS" > "$SETTINGS.tmp"
          mv "$SETTINGS.tmp" "$SETTINGS"
        else
          ${lib.getExe pkgs.jq} -n \
            --argjson mqtt '${mqttSettingsJson}' \
            --argjson gw '${gatewaySettingsJson}' \
            --arg pw "$MQTT_PASSWORD" \
            '{mqtt: ($mqtt + {password: $pw}), gateway: $gw}' > "$SETTINGS"
        fi
      '';
    };

    networking.firewall.allowedTCPPorts = [ cfg.port 3000 ];
  };
}
