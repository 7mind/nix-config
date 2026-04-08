{ config, lib, pkgs, ... }:

# Unified Hue lighting controller. Replaces both:
#
#   * the bento `mqtt-automation` systemd service (runtime rule engine)
#   * the python `hue-setup` oneShot (z2m group/scene provisioning)
#
# Two systemd units share one binary (`hue-controller`), wired so the
# provisioner runs first on every config change and the daemon starts
# only after a successful provision pass:
#
#   hue-controller-provision.service  (oneshot, after z2m + mosquitto)
#   hue-controller.service             (long-running, after provision)
#
# Both consume the same JSON config rendered from
# `smind.services.hue-controller.config` — host modules drop a single
# attrset there matching the `Config` schema in
# `pkg/hue-controller/src/config/mod.rs`.

let
  cfg = config.smind.services.hue-controller;
  yaml = pkgs.formats.json { };
in
{
  options.smind.services.hue-controller = {
    enable = lib.mkEnableOption "Unified zigbee2mqtt provisioner + runtime controller";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.hue-controller;
      defaultText = lib.literalExpression "pkgs.hue-controller";
      description = "hue-controller package to run.";
    };

    config = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Unified config consumed by both the provisioner and the daemon.
        Rendered as JSON. The structure must match the `Config` type in
        `pkg/hue-controller/src/config/mod.rs`:

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
        }
        ```

        Host modules typically build this via the `defineRooms` helper in
        `private/hosts/raspi5m/hue-lights-tools.nix`, which knows how to
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
  };

  config = lib.mkIf cfg.enable (
    let
      configFile = yaml.generate "hue-controller.json" cfg.config;

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

      # Provisioner: oneshot, runs after z2m is up. Re-runs whenever the
      # rendered JSON changes (via restartTriggers on the config file).
      systemd.services.hue-controller-provision = {
        description = "Apply declarative zigbee2mqtt groups + scenes from Nix config";
        wantedBy = [ "multi-user.target" ];
        after = [ "zigbee2mqtt.service" "mosquitto.service" "network-online.target" ];
        wants = [ "zigbee2mqtt.service" "mosquitto.service" "network-online.target" ];
        restartTriggers = [ configFile ];
        before = [ "hue-controller.service" ];
        script = ''
          exec ${cfg.package}/bin/hue-controller provision ${commonArgs}
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          LoadCredential = "mqtt-password:${cfg.mqtt.passwordFile}";
          Restart = "on-failure";
          RestartSec = 30;
          DynamicUser = true;
        };
      };

      # Long-running daemon. Starts only after the provisioner has
      # succeeded so its first state-refresh sees the right groups.
      systemd.services.hue-controller = {
        description = "Hue lighting runtime controller (replaces bento mqtt-automation)";
        wantedBy = [ "multi-user.target" ];
        after = [
          "hue-controller-provision.service"
          "mosquitto.service"
          "network-online.target"
        ];
        wants = [ "mosquitto.service" "network-online.target" ];
        requires = [ "hue-controller-provision.service" ];
        restartTriggers = [ configFile ];
        environment = {
          TZ = cfg.timezone;
          RUST_LOG = "hue_controller=info";
        };
        script = ''
          exec ${cfg.package}/bin/hue-controller daemon ${commonArgs} --timezone ${cfg.timezone}
        '';
        serviceConfig = {
          Type = "simple";
          Restart = "on-failure";
          RestartSec = 5;
          LoadCredential = "mqtt-password:${cfg.mqtt.passwordFile}";
          DynamicUser = true;
        };
      };
    }
  );
}
