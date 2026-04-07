{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.zigbee2mqtt;
  mosquittoCfg = config.smind.services.mosquitto;
  yamlFormat = pkgs.formats.yaml { };
  z2mDataDir = config.services.zigbee2mqtt.dataDir;
  groupsFile = yamlFormat.generate "zigbee2mqtt-groups.yaml" cfg.groups;
in
{
  options = {
    smind.services.zigbee2mqtt = {
      enable = lib.mkEnableOption "Zigbee2MQTT service";
      serialPort = lib.mkOption {
        type = lib.types.path;
        default = "/dev/ttyZigbee";
        description = "The serial port for the Zigbee controller.";
      };
      adapter = lib.mkOption {
        type = lib.types.str;
        description = "The Zigbee adapter type (e.g. zstack, ember).";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "The host to listen on.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 8080;
        description = "The port for the web frontend.";
      };
      groups = lib.mkOption {
        type = lib.types.attrsOf yamlFormat.type;
        default = { };
        example = lib.literalExpression ''
          {
            "1" = {
              friendly_name = "living room";
              devices = [ "0x001788010e8422bc/11" ];
            };
          }
        '';
        description = ''
          Declarative zigbee2mqtt group definitions, keyed by group id.

          When non-empty, a `groups.yaml` is rendered from this attrset and
          copied into the zigbee2mqtt data dir on every service start
          (matching the upstream `--no-preserve=mode` pattern used for
          `configuration.yaml`). The copy is destructive: any groups created
          interactively via the z2m frontend that are not declared here will
          be wiped on the next service restart.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.zigbee2mqtt = {
      enable = true;
      settings = {
        serial.port = cfg.serialPort;
        serial.adapter = cfg.adapter;
        frontend = {
          host = cfg.host;
          port = cfg.port;
        };
        mqtt = {
          server = "mqtt://localhost:${toString mosquittoCfg.port}";
          user = mosquittoCfg.user;
          password = "!secret mqtt_password";
        };
        homeassistant.enabled = true;
        homeassistant.experimental_event_entities = true;
        permit_join = false;
        advanced.log_output = [ "console" "syslog" ];
        advanced.channel = 15;
        advanced.last_seen = "ISO_8601";
      };
    };

    systemd.services.zigbee2mqtt.preStart = ''
      echo "mqtt_password: $(cat ${mosquittoCfg.passwordFile})" > ${z2mDataDir}/secret.yaml
    '' + lib.optionalString (cfg.groups != { }) ''
      ${lib.getExe' pkgs.coreutils "cp"} --no-preserve=mode ${groupsFile} ${z2mDataDir}/groups.yaml
    '';

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
