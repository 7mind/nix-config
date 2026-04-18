{ config, lib, pkgs, ... }:

# Unified MQTT lighting controller. Replaces both:
#
#   * the bento `mqtt-automation` systemd service (runtime rule engine)
#   * the python `hue-setup` oneShot (z2m group/scene provisioning)
#
# Two systemd units share one binary (`mqtt-controller`), wired so the
# provisioner runs first on every config change and the daemon starts
# only after a successful provision pass:
#
#   mqtt-controller-provision.service  (oneshot, after z2m + mosquitto)
#   mqtt-controller.service             (long-running, after provision)
#
# Both consume the same JSON config rendered from
# `smind.services.mqtt-controller.config` — host modules drop a single
# attrset there matching the `Config` schema in
# `pkg/mqtt-controller/src/config/mod.rs`.

let
  cfg = config.smind.services.mqtt-controller;
  yaml = pkgs.formats.json { };
in
{
  options.smind.services.mqtt-controller = {
    enable = lib.mkEnableOption "Unified zigbee2mqtt provisioner + runtime controller";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.mqtt-controller;
      defaultText = lib.literalExpression "pkgs.mqtt-controller";
      description = "mqtt-controller package to run.";
    };

    config = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Unified config consumed by both the provisioner and the daemon.
        Rendered as JSON. The structure must match the `Config` type in
        `pkg/mqtt-controller/src/config/mod.rs`:

        ```
        {
          name_by_address = { "0x..." = "hue-s-foo"; ... };
          devices = {
            "hue-l-foo" = { kind = "light"; ieee_address = "0x..."; };
            "hue-ms-foo" = {
              kind = "motion-sensor";
              ieee_address = "0x...";
              occupancy_timeout_seconds = 60;
              max_illuminance = 30;
              options = { occupancy_timeout = 60; motion_sensitivity = "high"; };
            };
            ...
          };
          rooms = [
            {
              name = "kitchen-cooker";
              group_name = "hue-lz-kitchen-cooker";
              id = 15;
              members = [ "hue-l-cooker-bottom/11" ... ];
              parent = "kitchen-all";
              devices = [ { device = "hue-ts-foo"; button = 2; } ];
              scenes = { ... };
              off_transition_seconds = 0.8;
              motion_off_cooldown_seconds = 0;
            }
            ...
          ];
          defaults = {
            cycle_window_seconds = 1.0;
            wall_switch = {
              brightness_step = 25;
              brightness_step_transition_seconds = 0.2;
              brightness_move_rate = 40;
            };
          };
          # Optional heating subsystem:
          heating = {
            zones = [ {
              name = "floor-bathroom";
              relay = "bosch-wt-bathroom";   # wall-thermostat device
              trvs = [
                { device = "bosch-trv-bath-1"; schedule = "bathroom"; }
              ];
            } ];
            schedules.bathroom = {
              monday = [
                { start = "00:00"; end = "06:00"; temperature = 18.0; }
                { start = "06:00"; end = "22:00"; temperature = 22.0; }
                { start = "22:00"; end = "24:00"; temperature = 18.0; }
              ];
              # tuesday..sunday required (same structure)
            };
            pressure_groups = [ ];
            heat_pump = { min_cycle_seconds = 300; min_pause_seconds = 180; };
            open_window = { detection_minutes = 20; inhibit_minutes = 80; };
          };
        }
        ```

        Host modules typically build this via the `defineRooms` helper in
        `private/hosts/raspi5m/mqtt-controller-tools.nix`, which knows how to
        translate the high-level Nix room/device/scene model into the
        flat JSON shape the controller expects.
      '';
      example = lib.literalExpression "{ rooms = [ ]; }";
    };

    mqtt = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "localhost";
        description = "MQTT broker hostname.";
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
        description = ''
          Path to a file containing the MQTT password (one line). Read by
          systemd's LoadCredential so the daemon process never sees the
          plain file path.
        '';
      };
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "UTC";
      example = "Europe/Amsterdam";
      description = ''
        IANA timezone for the daemon's time-of-day slot dispatch
        (day/night scene cycles). Should match the host's local time.
      '';
    };

    location = {
      latitude = lib.mkOption {
        type = lib.types.nullOr lib.types.float;
        default = null;
        example = 53.35;
        description = "Latitude for sunrise/sunset calculations. Required when schedules use sun-relative expressions.";
      };
      longitude = lib.mkOption {
        type = lib.types.nullOr lib.types.float;
        default = null;
        example = -6.26;
        description = "Longitude for sunrise/sunset calculations. Required when schedules use sun-relative expressions.";
      };
    };

    web = {
      enable = lib.mkEnableOption "Web dashboard for the mqtt-controller daemon";

      port = lib.mkOption {
        type = lib.types.port;
        default = 8780;
        description = "Port for the web dashboard HTTP/WebSocket server.";
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to open the web dashboard port in the firewall.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    let
      locationAttr = lib.optionalAttrs
        (cfg.location.latitude != null && cfg.location.longitude != null)
        { location = { inherit (cfg.location) latitude longitude; }; };
      mergedConfig = cfg.config // locationAttr;
      configFile = yaml.generate "mqtt-controller.json" mergedConfig;

      # The `--verbose` flag is the global one (clap `global = true`), so it
      # has to come BEFORE the subcommand on the command line. The provision
      # subcommand inherits it for free since clap parses globals at any
      # depth.
      commonArgs = lib.concatStringsSep " " [
        "--config ${configFile}"
        "--mqtt-host ${cfg.mqtt.host}"
        "--mqtt-port ${toString cfg.mqtt.port}"
        "--mqtt-user ${cfg.mqtt.user}"
        "--mqtt-password-file \"$CREDENTIALS_DIRECTORY/mqtt-password\""
      ];
    in
    {
      environment.systemPackages = [ cfg.package ];

      networking.firewall.allowedTCPPorts =
        lib.optionals (cfg.web.enable && cfg.web.openFirewall) [ cfg.web.port ];

      # Provisioner: oneshot, runs after z2m is up. Re-runs whenever the
      # rendered JSON changes (via restartTriggers on the config file).
      systemd.services.mqtt-controller-provision = {
        description = "Apply declarative zigbee2mqtt groups + scenes from Nix config";
        wantedBy = [ "multi-user.target" ];
        after = [ "zigbee2mqtt.service" "mosquitto.service" "network-online.target" ];
        wants = [ "zigbee2mqtt.service" "mosquitto.service" "network-online.target" ];
        restartTriggers = [ configFile ];
        before = [ "mqtt-controller.service" ];
        script = let
          z2mPort = config.smind.services.zigbee2mqtt.port;
          z2mWsUrl = "ws://localhost:${toString z2mPort}/api";
        in ''
          exec ${cfg.package}/bin/mqtt-controller --verbose provision ${commonArgs} \
            --z2m-ws-url ${z2mWsUrl}
        '';
        unitConfig = {
          # When the provisioner is active, ensure the daemon is
          # running. If the provisioner fails on first boot and only
          # succeeds on a later retry, Upholds re-queues a start job
          # for the daemon automatically.
          Upholds = "mqtt-controller.service";
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          LoadCredential = "mqtt-password:${cfg.mqtt.passwordFile}";
          Restart = "on-failure";
          RestartSec = 5;
          DynamicUser = true;
        };
      };

      # Force provisioner: same as the oneshot above, but with
      # `--force-options` so it rewrites every per-device option even
      # if z2m reports them as already applied. Escape hatch for
      # devices whose reported state diverges from the physical state
      # (e.g. Sonoff `inching_control`, `overload_protection`).
      #
      # NOT wanted by any target — run on demand:
      #
      #   sudo systemctl start mqtt-controller-force-provision.service
      #   sudo journalctl -u mqtt-controller-force-provision.service -f
      systemd.services.mqtt-controller-force-provision = {
        description = "Force-rewrite zigbee2mqtt device options (bypasses state-cache dedup)";
        after = [ "zigbee2mqtt.service" "mosquitto.service" "network-online.target" ];
        wants = [ "zigbee2mqtt.service" "mosquitto.service" "network-online.target" ];
        script = let
          z2mPort = config.smind.services.zigbee2mqtt.port;
          z2mWsUrl = "ws://localhost:${toString z2mPort}/api";
        in ''
          exec ${cfg.package}/bin/mqtt-controller --verbose provision ${commonArgs} \
            --z2m-ws-url ${z2mWsUrl} \
            --force-options
        '';
        serviceConfig = {
          Type = "oneshot";
          LoadCredential = "mqtt-password:${cfg.mqtt.passwordFile}";
          DynamicUser = true;
        };
      };

      # Long-running daemon. Starts only after the provisioner has
      # succeeded so its first state-refresh sees the right groups.
      systemd.services.mqtt-controller = {
        description = "MQTT lighting runtime controller (replaces bento mqtt-automation)";
        wantedBy = [ "multi-user.target" ];
        after = [
          "mqtt-controller-provision.service"
          "mosquitto.service"
          "network-online.target"
        ];
        wants = [ "mosquitto.service" "network-online.target" ];
        requires = [ "mqtt-controller-provision.service" ];
        restartTriggers = [ configFile ];
        environment = {
          TZ = cfg.timezone;
        };
        # `--verbose` is on by default for now: every command the
        # daemon publishes is logged in human-readable form with the
        # state-machine branch that produced it. Drop the flag here
        # once the runtime is stable to quiet the logs back down to
        # warnings/errors only.
        script = ''
          exec ${cfg.package}/bin/mqtt-controller --verbose daemon ${commonArgs} --timezone ${cfg.timezone} \
            ${lib.optionalString cfg.web.enable
              "--web-port ${toString cfg.web.port} --web-assets-dir ${cfg.package}/share/mqtt-controller/web"}
        '';
        serviceConfig = {
          Type = "simple";
          Restart = "always";
          RestartSec = 5;
          LoadCredential = "mqtt-password:${cfg.mqtt.passwordFile}";
          DynamicUser = true;
        };
      };
    }
  );
}
