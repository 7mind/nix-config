{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.mqtt-automations;

  yaml = pkgs.formats.yaml { };

  mqttUrl = "tcp://${cfg.mqtt.host}:${toString cfg.mqtt.port}";

  # Bento labels are restricted to ^[a-z0-9_]+$ (no leading underscore),
  # so the user-facing rule names get sanitized when used as labels or
  # client IDs. Hyphens become underscores; everything else passes through.
  sanitize = lib.replaceStrings [ "-" ] [ "_" ];

  # Build the action-level switch for one rule's handlers. Returns a list
  # of bento switch cases dispatching on the action plain-text payload,
  # plus a default case that drops unmatched messages.
  mkActionCases = ruleName: rule:
    let
      cacheLabel = "state_${sanitize ruleName}";

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
          debounceMs = handler.cycle.debounceMs;

          # Debounce gate: compare current epoch-ms against the in-memory
          # last-fired epoch-ms. If the delta is below the configured
          # window, drop the message; otherwise update the timestamp and
          # proceed. Implemented via timestamps because bento's `cache add`
          # operator ignores TTL on the memory cache (it checks raw map
          # presence before compaction — see
          # internal/impl/pure/cache_memory.go:223).
          debounceProcessors = lib.optionals (isCycle && debounceMs > 0) [
            {
              branch = {
                request_map = ''root = ""'';
                processors = [
                  {
                    cache = {
                      resource = cacheLabel;
                      operator = "get";
                      key = "${handler.cycle.stateKey}_last_ms";
                    };
                  }
                  {
                    "catch" = [
                      { mapping = ''root = "0"''; }
                    ];
                  }
                ];
                result_map = ''meta ${handler.cycle.stateKey}_last_ms = content().string()'';
              };
            }
            {
              mapping = ''
                let last = (meta("${handler.cycle.stateKey}_last_ms").or("0")).number().or(0)
                let now = timestamp_unix_milli()
                meta ${handler.cycle.stateKey}_now_ms = $now.string()
                root = if ($now - $last) < ${toString debounceMs} { deleted() } else { this }
              '';
            }
            {
              cache = {
                resource = cacheLabel;
                operator = "set";
                key = "${handler.cycle.stateKey}_last_ms";
                value = "\${! meta(\"${handler.cycle.stateKey}_now_ms\") }";
              };
            }
          ];

          cycleCase = {
            check = ''content().string() == "${action}"'';
            processors = debounceProcessors ++ [
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
              # `.or(0)` after `.number()` is the safety net: if the cache
              # value is somehow not parseable (e.g. it got polluted with
              # the literal string "null" by a prior failed run), reset to
              # 0 instead of erroring on every press forever after.
              {
                mapping = ''
                  let cur = (meta("${handler.cycle.stateKey}_cur").or("0")).number().or(0)
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
          throw "mqtt-automations rule '${ruleName}' action '${action}': handler must specify exactly one of `publish` or `cycle`, not both"
        else if isCycle then cycleCase
        else if isPublish then publishCase
        else throw "mqtt-automations rule '${ruleName}' action '${action}': handler must specify either `publish` or `cycle`";

      defaultCase = {
        processors = [
          { mapping = "root = deleted()"; }
        ];
      };
    in
    (lib.mapAttrsToList mkCase rule.handlers) ++ [ defaultCase ];

  # Build the rule-level switch case dispatching on the source MQTT topic.
  mkRuleCase = ruleName: rule: {
    check = ''meta("mqtt_topic") == "${rule.source}"'';
    processors = [
      # Stamp the output topic so the dynamic mqtt output knows where to publish.
      { mapping = ''meta out_topic = "${rule.target}"''; }
      # Dispatch on action value.
      { switch = mkActionCases ruleName rule; }
    ];
  };

  # Single bento config rendered from all rules. Uses a `broker` input to
  # combine each rule's source topic into one process, dispatches in the
  # pipeline by `meta("mqtt_topic")` (which the mqtt input populates
  # automatically), and publishes to a per-message dynamic topic via
  # `${! meta("out_topic") }` interpolation.
  bentoConfig = {
    http.enabled = false;

    # One in-memory cache resource per rule, so cycle indices and debounce
    # timestamps for different rules don't collide. State is in-process —
    # restarting the service resets all cycle indices to 0 and clears all
    # debounce windows. That's intentional.
    cache_resources = lib.mapAttrsToList
      (name: _rule: {
        label = "state_${sanitize name}";
        memory = { };
      })
      cfg.rules;

    input = {
      broker = {
        inputs = lib.mapAttrsToList
          (name: rule: {
            mqtt = {
              urls = [ mqttUrl ];
              topics = [ rule.source ];
              client_id = "bento_${sanitize name}_in";
              user = cfg.mqtt.user;
              password = "\${MQTT_PASSWORD}";
            };
          })
          cfg.rules;
      };
    };

    pipeline.processors = [
      {
        switch = (lib.mapAttrsToList mkRuleCase cfg.rules) ++ [
          {
            processors = [
              { mapping = "root = deleted()"; }
            ];
          }
        ];
      }
    ];

    output = {
      mqtt = {
        urls = [ mqttUrl ];
        topic = "\${! meta(\"out_topic\") }";
        client_id = "bento_mqtt_automation_out";
        user = cfg.mqtt.user;
        password = "\${MQTT_PASSWORD}";
      };
    };
  };

  configFile =
    let
      raw = yaml.generate "bento-mqtt-automation-raw.yaml" bentoConfig;
    in
    pkgs.runCommand "bento-mqtt-automation.yaml"
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
        Declarative MQTT automation rules. All rules run in a single
        bento process: each rule subscribes to its `source` MQTT topic
        (which should publish a plain-text action value per message,
        typically a zigbee2mqtt `<device>/action` subtopic), dispatches
        on the action value, and publishes a payload to its `target`
        MQTT topic.

        Each handler must specify exactly one of:
          - `publish`: a fixed payload to publish on the target topic
          - `cycle`: a list of payloads to cycle through, with the
                     current index held in process memory (resets to 0
                     when the bento service restarts)
      '';
      default = { };
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          source = lib.mkOption {
            type = lib.types.str;
            example = "zigbee2mqtt/mid-bedroom-switch/action";
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
                        description = "Cache key used to track the cycle index.";
                      };
                      values = lib.mkOption {
                        type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
                        description = "List of payloads to cycle through; each press advances by one and wraps at the end.";
                      };
                      debounceMs = lib.mkOption {
                        type = lib.types.ints.unsigned;
                        default = 0;
                        example = 600;
                        description = ''
                          Debounce window in milliseconds. When non-zero,
                          presses that arrive within this many milliseconds of
                          a previously-accepted press are dropped (first-wins).
                          Useful for cycle handlers targeting zigbee groups,
                          where rapid commands can cause group members to
                          drift out of sync.

                          Implemented as a per-key timestamp comparison
                          against the in-memory state cache (no TTL needed),
                          because bento's memory-cache `add` operator ignores
                          TTL.

                          0 disables debouncing.
                        '';
                      };
                    };
                  });
                  default = null;
                  description = "Cycle through a list of payloads.";
                };
              };
            });
          };
        };
      });
    };
  };

  config = lib.mkIf (cfg.enable && cfg.rules != { }) {
    systemd.services.mqtt-automation = {
      description = "MQTT automation rules (Bento)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "mosquitto.service" ];
      wants = [ "mosquitto.service" ];

      script = ''
        export MQTT_PASSWORD=$(cat "$CREDENTIALS_DIRECTORY/mqtt-password")
        exec ${cfg.package}/bin/bento -c ${configFile}
      '';

      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 5;
        LoadCredential = "mqtt-password:${cfg.mqtt.passwordFile}";
        DynamicUser = true;
      };
    };
  };
}
