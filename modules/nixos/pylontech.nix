{ config, lib, pkgs, cfg-flakes, cfg-meta, ... }:

# Pylontech battery poller. Two implementations live side by side:
#
#   * `python` — the original Python `poller` from the upstream
#     `python-pylontech` flake (`cfg-flakes.pylontech.default`).
#   * `rust`   — the standalone Rust `pylontech-mqtt-adapter` crate
#     shipped in the same upstream repo under `rust-mqtt-adapter/` and
#     packaged via the overlay (`pkgs.pylontech-mqtt-adapter`).
#
# Selected via `smind.services.pylontech.implementation`. The host
# config picks one; the other branch is dead code at evaluation time.

let
  cfg = config.smind.services.pylontech;
in
{
  options = {
    smind.services.pylontech = {
      enable = lib.mkEnableOption "Pylontech battery poller";
      implementation = lib.mkOption {
        type = lib.types.enum [ "python" "rust" ];
        default = "python";
        description = ''
          Which poller implementation to run.
          - "python": the original `poller` script from the upstream flake.
          - "rust": the standalone `pylontech-mqtt-adapter` Rust crate.
        '';
      };
      rs485Host = lib.mkOption {
        type = lib.types.str;
        description = "Hostname of the RS485 gateway.";
      };
      rs485Port = lib.mkOption {
        type = lib.types.port;
        default = 23;
        description = "TCP port of the RS485 gateway. Only used by the rust implementation.";
      };
      pollInterval = lib.mkOption {
        type = lib.types.int;
        default = 5000;
        description = "Polling interval in milliseconds.";
      };
      managementInterval = lib.mkOption {
        type = lib.types.int;
        default = 30000;
        description = "Management info polling interval in milliseconds. Only used by the rust implementation.";
      };
      scanStart = lib.mkOption {
        type = lib.types.int;
        default = 2;
        description = "First module address to probe (inclusive). Only used by the rust implementation.";
      };
      scanEnd = lib.mkOption {
        type = lib.types.int;
        default = 9;
        description = "Last module address to probe (inclusive). Only used by the rust implementation.";
      };
      mqttHost = lib.mkOption {
        type = lib.types.str;
        description = "MQTT broker hostname.";
      };
      mqttPort = lib.mkOption {
        type = lib.types.port;
        default = 1883;
        description = "MQTT broker port. Only used by the rust implementation.";
      };
      mqttUser = lib.mkOption {
        type = lib.types.str;
        default = "mqtt";
        description = "MQTT username. Only used by the rust implementation.";
      };
      mqttPasswordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to the file containing the MQTT password.";
      };
    };
  };

  # Two mutually-exclusive `mkIf`s rather than a raw `if-then-else`:
  # the module system can push `mkIf` down lazily without forcing the
  # condition, while a plain Nix `if` would evaluate `cfg.implementation`
  # mid-config-merge and trip an infinite recursion.
  config = lib.mkIf cfg.enable (lib.mkMerge [
    (lib.mkIf (cfg.implementation == "python") {
      systemd.services.pylontech-poller = {
        description = "Pylontech Battery Poller (python)";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = ''
            ${cfg-flakes.pylontech.default}/bin/poller ${cfg.rs485Host} \
              --interval ${toString cfg.pollInterval} \
              --mqtt-host ${cfg.mqttHost} \
              --mqtt-password ${cfg.mqttPasswordFile}
          '';
          Restart = "always";
        };
      };
    })
    (lib.mkIf (cfg.implementation == "rust") {
      systemd.services.pylontech-poller = {
        description = "Pylontech Battery Poller (rust mqtt adapter)";
        after = [ "network-online.target" "mosquitto.service" ];
        wants = [ "network-online.target" "mosquitto.service" ];
        wantedBy = [ "multi-user.target" ];
        script = ''
          exec ${pkgs.pylontech-mqtt-adapter}/bin/pylontech-mqtt-adapter \
            ${cfg.rs485Host} \
            --source-port ${toString cfg.rs485Port} \
            --interval-millis ${toString cfg.pollInterval} \
            --management-interval-millis ${toString cfg.managementInterval} \
            --scan-start ${toString cfg.scanStart} \
            --scan-end ${toString cfg.scanEnd} \
            --mqtt-host ${cfg.mqttHost} \
            --mqtt-port ${toString cfg.mqttPort} \
            --mqtt-user ${cfg.mqttUser} \
            --mqtt-password-file "$CREDENTIALS_DIRECTORY/mqtt-password"
        '';
        serviceConfig = {
          Type = "simple";
          Restart = "on-failure";
          RestartSec = 5;
          LoadCredential = "mqtt-password:${cfg.mqttPasswordFile}";
          DynamicUser = true;
        };
      };
    })
  ]);
}
