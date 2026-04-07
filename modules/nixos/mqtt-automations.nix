{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.mqtt-automations;

  yaml = pkgs.formats.yaml { };

  stateRoot = "/var/lib/mqtt-automations";

  # Render a single rule into a bento config attrset.
  renderRule = name: rule:
    let
      cacheLabel = "state";
      cacheDir = "${stateRoot}/${name}";

      mqttUrl = "tcp://${cfg.mqtt.host}:${toString cfg.mqtt.port}";

      # Build a single switch case from one (action, handler) pair.
      mkCase = action: handler:
        let
          isCycle = handler.cycle != null;
          isPublish = handler.publish != null;

          publishCase = {
            check = ''content().string() == "${action}"'';
            processors = [
              { mapping = "root = ${builtins.toJSON handler.publish}"; }
            ];
          };

          cycleLen = lib.length handler.cycle.values;

          cycleCase = {
            check = ''content().string() == "${action}"'';
            processors = [
              # Read current preset index from cache; default to "0" on miss.
              {
                branch = {
                  request_map = ''root = ""'';
                  processors = [
                    {
                      cache = {
                        resource = cacheLabel;
                        operator = "get";
                        key = handler.cycle.stateKey;
                      };
                    }
                    {
                      "catch" = [
                        { mapping = ''root = "0"''; }
                      ];
                    }
                  ];
                  result_map = ''meta ${handler.cycle.stateKey}_cur = content().string()'';
                };
              }
              # Pick current preset, compute next index for storage.
              {
                mapping = ''
                  let cur = (meta("${handler.cycle.stateKey}_cur").or("0")).number()
                  let next = ($cur + 1) % ${toString cycleLen}
                  let presets = ${builtins.toJSON handler.cycle.values}
                  meta ${handler.cycle.stateKey}_next = $next.string()
                  root = $presets.index($cur)
                '';
              }
              # Persist the next index for the following press.
              {
                cache = {
                  resource = cacheLabel;
                  operator = "set";
                  key = handler.cycle.stateKey;
                  value = "\${! meta(\"${handler.cycle.stateKey}_next\") }";
                };
              }
            ];
          };
        in
        if isCycle && isPublish then
          throw "mqtt-automations rule '${name}' action '${action}': handler must specify exactly one of `publish` or `cycle`, not both"
        else if isCycle then cycleCase
        else if isPublish then publishCase
        else throw "mqtt-automations rule '${name}' action '${action}': handler must specify either `publish` or `cycle`";

      cases = lib.mapAttrsToList mkCase rule.handlers;

      # Default branch in the switch: drop unhandled messages so the output isn't spammed.
      defaultCase = {
        processors = [
          { mapping = "root = deleted()"; }
        ];
      };
    in
    {
      http.enabled = false;

      cache_resources = [
        {
          label = cacheLabel;
          file.directory = cacheDir;
        }
      ];

      input = {
        mqtt = {
          urls = [ mqttUrl ];
          topics = [ rule.source ];
          client_id = "bento-${name}-in";
          user = cfg.mqtt.user;
          password = "\${MQTT_PASSWORD}";
        };
      };

      pipeline.processors = [
        # The source topic is expected to publish a plain-text action value
        # per message (e.g. zigbee2mqtt's `<device>/action` subtopic), so we
        # dispatch directly on `content().string()` without JSON parsing.
        { switch = cases ++ [ defaultCase ]; }
      ];

      output = {
        mqtt = {
          urls = [ mqttUrl ];
          topic = rule.target;
          client_id = "bento-${name}-out";
          user = cfg.mqtt.user;
          password = "\${MQTT_PASSWORD}";
        };
      };
    };

  # Render a rule and check it with `bento lint` at build time.
  ruleConfigFile = name: rule:
    let
      raw = yaml.generate "bento-${name}-raw.yaml" (renderRule name rule);
    in
    pkgs.runCommand "bento-${name}.yaml"
      {
        nativeBuildInputs = [ pkgs.buildPackages.bento ];
      } ''
      cp ${raw} config.yaml
      bento lint --skip-env-var-check config.yaml
      cp config.yaml $out
    '';
in
{
  options.smind.services.mqtt-automations = {
    enable = lib.mkEnableOption "Declarative MQTT automations via Bento";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.bento;
      defaultText = lib.literalExpression "pkgs.bento";
      description = "Bento package to run.";
    };

    mqtt = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "localhost";
        description = "MQTT broker host.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 1883;
        description = "MQTT broker port.";
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "mqtt";
        description = "MQTT username.";
      };
      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to a file containing the MQTT password.";
      };
    };

    rules = lib.mkOption {
      description = ''
        Declarative MQTT automation rules. Each rule subscribes to a single
        source MQTT topic that publishes a plain-text action value per
        message (typically a zigbee2mqtt `<device>/action` subtopic),
        dispatches on the action value, and publishes a payload to a target
        MQTT topic.

        Each handler must specify exactly one of:
          - `publish`: a fixed payload to publish on the target topic
          - `cycle`: a list of payloads to cycle through, with the current
                     index persisted across restarts in a per-rule file cache
      '';
      default = { };
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          source = lib.mkOption {
            type = lib.types.str;
            example = "zigbee2mqtt/mid-bedroom-switch";
            description = "MQTT topic to subscribe to.";
          };
          target = lib.mkOption {
            type = lib.types.str;
            example = "zigbee2mqtt/mid bedroom ceiling/set";
            description = "MQTT topic to publish to.";
          };
          handlers = lib.mkOption {
            description = "Map from action value to handler.";
            default = { };
            type = lib.types.attrsOf (lib.types.submodule {
              options = {
                publish = lib.mkOption {
                  type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
                  default = null;
                  example = { state = "OFF"; };
                  description = "Static payload to publish to the target topic.";
                };
                cycle = lib.mkOption {
                  type = lib.types.nullOr (lib.types.submodule {
                    options = {
                      stateKey = lib.mkOption {
                        type = lib.types.str;
                        description = "Cache key used to persist the cycle index.";
                      };
                      values = lib.mkOption {
                        type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
                        description = "List of payloads to cycle through; each press advances by one and wraps at the end.";
                      };
                    };
                  });
                  default = null;
                  description = "Cycle through a list of payloads, persisting the current index.";
                };
              };
            });
          };
        };
      });
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services = lib.mapAttrs' (name: rule:
      lib.nameValuePair "mqtt-automation-${name}" {
        description = "MQTT automation '${name}' (Bento)";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" "mosquitto.service" ];
        wants = [ "mosquitto.service" ];

        script = ''
          export MQTT_PASSWORD=$(cat "$CREDENTIALS_DIRECTORY/mqtt-password")
          exec ${cfg.package}/bin/bento -c ${ruleConfigFile name rule}
        '';

        serviceConfig = {
          Type = "simple";
          Restart = "on-failure";
          RestartSec = 5;
          LoadCredential = "mqtt-password:${cfg.mqtt.passwordFile}";
          DynamicUser = true;
          # systemd creates /var/lib/mqtt-automations/<name> owned by the
          # dynamic user; bento's file cache requires this directory to exist.
          StateDirectory = "mqtt-automations/${name}";
          StateDirectoryMode = "0700";
        };
      }
    ) cfg.rules;
  };
}
