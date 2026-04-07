{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.mqtt-automations;

  yaml = pkgs.formats.yaml { };

  mqttUrl = "tcp://${cfg.mqtt.host}:${toString cfg.mqtt.port}";

  # Bento labels are restricted to ^[a-z0-9_]+$ (no leading underscore),
  # so the user-facing rule names get sanitized when used as labels or
  # client IDs. Hyphens become underscores; everything else passes through.
  sanitize = lib.replaceStrings [ "-" ] [ "_" ];

  # Resolve a rule's effective cache label. When a rule sets `cacheLabel`
  # explicitly, two rules can share state by using the same value.
  # Otherwise we derive a unique label from the rule name.
  ruleCacheLabel = ruleName: rule:
    if rule.cacheLabel != null then rule.cacheLabel else "state_${sanitize ruleName}";

  # Build the action-level switch for one rule's handlers. Returns a list
  # of bento switch cases dispatching either on the action plain-text
  # payload (`format = "action"`) or on user-provided bloblang checks
  # (`format = "json"`), plus a default case that drops unmatched
  # messages.
  mkActionCases = ruleName: rule:
    let
      cacheLabel = ruleCacheLabel ruleName rule;

      # Render `cacheWrites` as a list of cache.set processors that run
      # after the handler's main payload mapping. Used both by handlers
      # that want explicit cache side effects and by the resetCycles
      # convenience macro on cycle-targeting publish handlers.
      mkCacheWrites = writes: lib.mapAttrsToList
        (key: value: {
          cache = {
            resource = cacheLabel;
            operator = "set";
            inherit key value;
          };
        })
        writes;

      mkCase = action: handler:
        let
          isCycle = handler.cycle != null;
          isPublish = handler.publish != null || handler.publishMapping != null;
          hasBoth = handler.publish != null && handler.publishMapping != null;

          # Default check varies by source format. For action-format
          # rules we dispatch on the plain-text payload matching the
          # handler attribute key; for json-format rules the user must
          # supply an explicit check expression.
          defaultCheck =
            if rule.format == "action" then
              ''content().string() == "${action}"''
            else
              throw "mqtt-automations rule '${ruleName}' action '${action}': handlers in a json-format rule must provide an explicit `check`";
          checkExpr = if handler.check != null then handler.check else defaultCheck;

          # For each cycle stateKey listed in `resetCycles`, render cache
          # writes that zero out both the cycle index and the debounce
          # timestamp for that cycle. Used by e.g. an off handler to
          # restart the cycle from preset 0 next time the cycle handler
          # fires, without being held back by the debounce window.
          resetProcessors = lib.concatMap
            (stateKey: [
              {
                cache = {
                  resource = cacheLabel;
                  operator = "set";
                  key = stateKey;
                  value = "0";
                };
              }
              {
                cache = {
                  resource = cacheLabel;
                  operator = "set";
                  key = "${stateKey}_last_ms";
                  value = "0";
                };
              }
            ])
            handler.resetCycles;

          publishMappingText =
            if handler.publishMapping != null then handler.publishMapping
            else "root = ${builtins.toJSON handler.publish}";

          publishCase =
            if hasBoth then
              throw "mqtt-automations rule '${ruleName}' action '${action}': handler must specify exactly one of `publish` or `publishMapping`, not both"
            else {
              check = checkExpr;
              processors = [
                { mapping = publishMappingText; }
              ] ++ resetProcessors ++ mkCacheWrites handler.cacheWrites;
            };

          debounceMs = handler.cycle.debounceMs;

          # A cycle handler must specify exactly one of `values` (flat
          # list) or `slots` (time-of-day slots). Both paths render
          # different bloblang but share the same debounce, cache,
          # and control-flow structure.
          useSlots = handler.cycle.slots != null;
          useValues = handler.cycle.values != null;

          # The mapping processor for the non-slotted (flat) case.
          flatCycleMapping = ''
            let cur = (meta("${handler.cycle.stateKey}_cur").or("0")).number().or(0)
            let next = ($cur + 1) % ${toString (lib.length handler.cycle.values)}
            let presets = ${builtins.toJSON handler.cycle.values}
            meta ${handler.cycle.stateKey}_next = $next.string()
            root = $presets.index($cur)
          '';

          # The mapping processor for the slotted (time-of-day) case.
          # State is stored as `"slot_name:index"` in a single cache key;
          # resetting the cache to `"0"` makes last_slot parse to "0"
          # which won't match any real slot, so the next press starts
          # at index 0 of whichever slot is current.
          slottedCycleMapping =
            let
              slotNames = lib.attrNames handler.cycle.slots;
              # Build `if cond1 { "name1" } else if cond2 { "name2" } else { "name1" }`
              # where the final else is a fallback (the hour ranges
              # should cover all 24 hours so the else is unreachable in
              # practice; using the first slot as a safety net).
              mkSlotPredicate = slotName:
                let
                  slot = handler.cycle.slots.${slotName};
                  from = slot.fromHour;
                  to = slot.toHour;
                in
                if from < to then
                  ''$h >= ${toString from} && $h < ${toString to}''
                else
                  ''$h >= ${toString from} || $h < ${toString to}'';

              slotNameExpr =
                let
                  chain = lib.foldr
                    (slotName: rest:
                      ''if ${mkSlotPredicate slotName} { "${slotName}" } else ${rest}''
                    )
                    ''{ "${lib.head slotNames}" }''
                    slotNames;
                in
                chain;

              # `if current_slot == "day" { 3 } else if ... else { 0 }`
              slotLenExpr = lib.foldr
                (slotName: rest:
                  ''if $current_slot == "${slotName}" { ${toString (lib.length handler.cycle.slots.${slotName}.values)} } else ${rest}''
                )
                ''{ 1 }''
                slotNames;

              # `if current_slot == "day" { [...] } else if ... else { [] }`
              slotValuesExpr = lib.foldr
                (slotName: rest:
                  ''if $current_slot == "${slotName}" { ${builtins.toJSON handler.cycle.slots.${slotName}.values} } else ${rest}''
                )
                ''{ [] }''
                slotNames;
            in
            ''
              let h = timestamp_unix().ts_format("15", "Local").number()
              let current_slot = ${slotNameExpr}
              let raw = (meta("${handler.cycle.stateKey}_cur").or("")).string()
              let parts = $raw.split(":")
              let last_slot = $parts.index(0).or("")
              let last_index = $parts.index(1).or("0").number().or(0)
              let current_len = ${slotLenExpr}
              let index = if $current_slot == $last_slot { ($last_index + 1) % $current_len } else { 0 }
              let current_values = ${slotValuesExpr}
              meta ${handler.cycle.stateKey}_next = $current_slot + ":" + $index.string()
              root = $current_values.index($index)
            '';

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
                if ($now - $last) < ${toString debounceMs} { root = deleted() }
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

          cycleCase =
            if useSlots && useValues then
              throw "mqtt-automations rule '${ruleName}' action '${action}': cycle must specify exactly one of `values` or `slots`, not both"
            else if !useSlots && !useValues then
              throw "mqtt-automations rule '${ruleName}' action '${action}': cycle must specify either `values` or `slots`"
            else {
              check = checkExpr;
              processors = debounceProcessors ++ [
                # Read current cycle state from cache; default to "0" on
                # miss. For flat cycles the cache holds an integer index;
                # for slotted cycles it holds "slot:index".
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
                # Pick current preset, compute next state for storage.
                # `.or(0)` after `.number()` is the safety net: if the cache
                # value is somehow not parseable (e.g. it got polluted with
                # the literal string "null" by a prior failed run), reset to
                # 0 instead of erroring on every press forever after.
                {
                  mapping = if useSlots then slottedCycleMapping else flatCycleMapping;
                }
                # Persist the next state for the following press.
                {
                  cache = {
                    resource = cacheLabel;
                    operator = "set";
                    key = handler.cycle.stateKey;
                    value = "\${! meta(\"${handler.cycle.stateKey}_next\") }";
                  };
                }
              ] ++ mkCacheWrites handler.cycle.cacheWrites;
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
  mkRuleCase = ruleName: rule:
    let
      cacheLabel = ruleCacheLabel ruleName rule;

      # When the source publishes JSON state (e.g. a motion sensor), the
      # rule's first processor parses it so handler checks can use
      # `this.<field>` directly.
      parseJsonProcessors = lib.optional (rule.format == "json") {
        mapping = "root = content().parse_json()";
      };

      # For each cache key listed in `cacheReads`, render a branch
      # processor that loads it into a metadata key with the same name.
      # Used by motion-sensor rules to check the shared `lights_state`
      # flag before deciding whether to fire.
      cacheReadProcessors = lib.map
        (key: {
          branch = {
            request_map = ''root = ""'';
            processors = [
              {
                cache = {
                  resource = cacheLabel;
                  operator = "get";
                  inherit key;
                };
              }
              {
                "catch" = [
                  { mapping = ''root = ""''; }
                ];
              }
            ];
            result_map = ''meta ${key} = content().string()'';
          };
        })
        rule.cacheReads;
    in
    {
      check = ''meta("mqtt_topic") == "${rule.source}"'';
      processors =
        parseJsonProcessors
        ++ [
          # Stamp the output topic so the dynamic mqtt output knows where to publish.
          { mapping = ''meta out_topic = "${rule.target}"''; }
        ]
        ++ cacheReadProcessors
        ++ [
          # Dispatch on the per-handler check expression.
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

    # In-memory cache resources for cycle/debounce/flag state. By default
    # each rule gets its own resource derived from its name so state
    # doesn't bleed between unrelated rules. Two rules can intentionally
    # share state by both setting the same `cacheLabel` — we dedup the
    # rendered resource list so the shared label produces a single
    # resource. State is in-process; restarting the service clears all
    # cycle indices and debounce windows. That's intentional.
    cache_resources = lib.map
      (label: { inherit label; memory = { }; })
      (lib.unique (lib.mapAttrsToList ruleCacheLabel cfg.rules));

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
          cacheLabel = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "landing";
            description = ''
              In-memory cache resource label used by this rule's cycle
              state, debounce timestamps, and any explicit cacheReads/
              cacheWrites. When null (default), a unique label is
              derived from the rule name. Setting an explicit value
              that two rules share lets them both read and write the
              same flags — used for example to share an
              `lights_state` flag between a switch rule and a motion
              sensor rule that target the same room.
            '';
          };
          format = lib.mkOption {
            type = lib.types.enum [ "action" "json" ];
            default = "action";
            description = ''
              How the source topic's payload is parsed before
              dispatching to handlers.

              - `"action"` (default): the payload is treated as a
                plain-text action string (e.g. zigbee2mqtt's
                `<device>/action` subtopic). Handler dispatch
                defaults to `content().string() == "<handler-name>"`.
              - `"json"`: the payload is parsed as JSON and the
                resulting object becomes `this` for handler check
                expressions. Each handler must provide an explicit
                `check`. Used for sources like Hue motion sensors
                that publish state JSON on their main topic.
            '';
          };
          cacheReads = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "lights_state" ];
            description = ''
              Cache keys to load into metadata before handler
              dispatch. For each key listed here, the rule renders a
              cache.get against the rule's cacheLabel and stores the
              result (or empty string on miss) in `meta("<key>")`.
              Handlers can then reference these via
              `meta("<key>").or("")` in their check expressions and
              bloblang.
            '';
          };
          handlers = lib.mkOption {
            description = "Map from action value to handler.";
            default = { };
            type = lib.types.attrsOf (lib.types.submodule {
              options = {
                check = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = ''this.occupancy == true && (meta("lights_state").or("")) == ""'';
                  description = ''
                    Custom bloblang dispatch expression for this
                    handler. When null (default), the renderer uses
                    `content().string() == "<handler-name>"` for
                    `format = "action"` rules. Required for
                    `format = "json"` rules, since plain-text matching
                    on the handler name doesn't apply once the
                    payload has been parsed into `this`.
                  '';
                };
                publish = lib.mkOption {
                  type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
                  default = null;
                  example = { state = "OFF"; };
                  description = "Static payload to publish to the target topic.";
                };
                publishMapping = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = ''
                    let h = timestamp_unix().ts_format("15", "Local").number()
                    root = if $h >= 6 && $h < 23 { {"scene_recall": 1} } else { {"scene_recall": 3} }
                  '';
                  description = ''
                    Raw bloblang mapping to compute the publish payload.
                    Mutually exclusive with `publish`. Used when the
                    payload depends on runtime state (e.g. time of day,
                    cache values) rather than being a fixed Nix
                    attrset.
                  '';
                };
                resetCycles = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  example = [ "preset_idx" ];
                  description = ''
                    Cycle stateKeys to reset after this publish handler
                    fires. Each entry zeroes out both the cycle index
                    (so the next press of the cycle handler plays the
                    first preset) and the cycle's debounce timestamp
                    (so the next press fires immediately even if it
                    arrives within the debounce window).

                    Typical use: an `off_press_release` publish handler
                    that resets the on-press cycle so OFF→ON always
                    starts at the first preset instead of resuming
                    where the cycle left off.
                  '';
                };
                cacheWrites = lib.mkOption {
                  type = lib.types.attrsOf lib.types.str;
                  default = { };
                  example = { lights_state = "user"; };
                  description = ''
                    Cache key/value writes to perform after this
                    handler's main payload publishes. Used to maintain
                    cross-handler flags such as `lights_state` for
                    motion-sensor cancellation. Writes are emitted as
                    cache.set processors against the rule's cacheLabel.
                  '';
                };
                cycle = lib.mkOption {
                  type = lib.types.nullOr (lib.types.submodule {
                    options = {
                      stateKey = lib.mkOption {
                        type = lib.types.str;
                        description = "Cache key used to track the cycle state.";
                      };
                      values = lib.mkOption {
                        type = lib.types.nullOr (lib.types.listOf (lib.types.attrsOf lib.types.anything));
                        default = null;
                        description = ''
                          Flat list of payloads to cycle through; each
                          press advances by one and wraps at the end.
                          Mutually exclusive with `slots`.
                        '';
                      };
                      slots = lib.mkOption {
                        type = lib.types.nullOr (lib.types.attrsOf (lib.types.submodule {
                          options = {
                            fromHour = lib.mkOption {
                              type = lib.types.ints.between 0 23;
                              description = "Start hour (inclusive, local time).";
                            };
                            toHour = lib.mkOption {
                              type = lib.types.ints.between 0 23;
                              description = "End hour (exclusive, local time). When `toHour <= fromHour` the slot wraps around midnight.";
                            };
                            values = lib.mkOption {
                              type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
                              description = "Payloads to cycle through while this slot is active.";
                            };
                          };
                        }));
                        default = null;
                        description = ''
                          Time-of-day slots for the cycle, keyed by
                          slot name. When set (mutually exclusive with
                          `values`), each press evaluates the current
                          local hour, finds the matching slot, and
                          cycles through that slot's values. Switching
                          slots between presses restarts the cycle at
                          index 0 of the new slot.

                          Cycle state is stored as `"slot_name:index"`
                          in a single cache key; `resetCycles` on a
                          publish handler still works — writing "0" to
                          the key produces a last_slot that can't match
                          any real slot, so the next press starts fresh
                          at index 0 of whichever slot is current.
                        '';
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
                      cacheWrites = lib.mkOption {
                        type = lib.types.attrsOf lib.types.str;
                        default = { };
                        example = { lights_state = "user"; };
                        description = ''
                          Cache key/value writes to perform after this
                          cycle handler emits its preset. Same shape as
                          the publish handler's `cacheWrites`. Used to
                          maintain cross-handler flags such as
                          `lights_state` for motion-sensor cancellation.
                        '';
                      };
                    };
                  });
                  default = null;
                  description = "Cycle through a list of payloads (flat or slot-based).";
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
