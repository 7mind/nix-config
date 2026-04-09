{ config, lib, pkgs, cfg-flakes, cfg-meta, ... }:

# Qendercore inverter cloud → MQTT adapter. Two implementations live
# side by side:
#
#   * `python` — the original `mqtt_main.py` script from the upstream
#     `qendercore-adapter` flake, run via `python3` with the deps from
#     `requirements.txt` baked in.
#   * `rust`   — the standalone `qendercore-mqtt-adapter` Rust crate
#     shipped in the same upstream flake as a separate package.
#
# Selected via `smind.services.qendercore.implementation`. The host
# config picks one; the other branch is dead code at evaluation time.

let
  cfg = config.smind.services.qendercore;

  qendercorePython = pkgs.python3.withPackages (ps: with ps; [
    urllib3
    paho-mqtt
    ha-mqtt-discoverable
  ]);

  qendercoreMqttRunner = pkgs.writeShellScript "qendercore-mqtt-runner" ''
    set -euo pipefail
    qc_login="$(${pkgs.jq}/bin/jq -r .login ${cfg.credentialsFile})"
    qc_password="$(${pkgs.jq}/bin/jq -r .password ${cfg.credentialsFile})"
    exec ${qendercorePython}/bin/python3 ${cfg-flakes.qendercore-adapter.outPath}/mqtt_main.py \
      --qc-login "$qc_login" \
      --qc-password "$qc_password" \
      --mqtt-host ${cfg.mqttHost} \
      --mqtt-user ${cfg.mqttUser} \
      --mqtt-password ${cfg.mqttPasswordFile}
  '';

  rustAdapter = cfg-flakes.qendercore-adapter.packages.${pkgs.system}.qendercore-mqtt-adapter;
in
{
  options = {
    smind.services.qendercore = {
      enable = lib.mkEnableOption "Qendercore MQTT adapter";
      implementation = lib.mkOption {
        type = lib.types.enum [ "python" "rust" ];
        default = "python";
        description = ''
          Which adapter implementation to run.
          - "python": the original `mqtt_main.py` script from the upstream flake.
          - "rust": the standalone `qendercore-mqtt-adapter` Rust crate.
        '';
      };
      credentialsFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to the JSON file with Qendercore login and password
          (`{"login": "...", "password": "..."}`). Used by both
          implementations; the rust branch parses it via jq at startup
          rather than expecting two separate files.
        '';
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
        description = "MQTT username.";
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
      systemd.services.qendercore-mqtt = {
        description = "Qendercore MQTT adapter (python)";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${qendercoreMqttRunner}";
          Restart = "always";
        };
      };
    })
    (lib.mkIf (cfg.implementation == "rust") {
      systemd.services.qendercore-mqtt = {
        description = "Qendercore MQTT adapter (rust)";
        after = [ "network-online.target" "mosquitto.service" ];
        wants = [ "network-online.target" "mosquitto.service" ];
        wantedBy = [ "multi-user.target" ];
        # The rust binary takes login as a CLI flag and password as a
        # file path, but our secret is a single JSON blob. Parse it
        # once at startup with jq, write the password to the unit's
        # private RuntimeDirectory, and pass --qc-login on the command
        # line. The runtime dir vanishes on stop, so the password
        # never lingers on disk past the service lifetime.
        script = ''
          qc_login=$(${pkgs.jq}/bin/jq -r .login "$CREDENTIALS_DIRECTORY/qcore-credentials")
          ${pkgs.jq}/bin/jq -r .password "$CREDENTIALS_DIRECTORY/qcore-credentials" > "$RUNTIME_DIRECTORY/qc-password"
          exec ${rustAdapter}/bin/qendercore-mqtt-adapter \
            --qc-login "$qc_login" \
            --qc-password-file "$RUNTIME_DIRECTORY/qc-password" \
            --cache-dir "$STATE_DIRECTORY" \
            --mqtt-host ${cfg.mqttHost} \
            --mqtt-port ${toString cfg.mqttPort} \
            --mqtt-user ${cfg.mqttUser} \
            --mqtt-password-file "$CREDENTIALS_DIRECTORY/mqtt-password"
        '';
        serviceConfig = {
          Type = "simple";
          Restart = "on-failure";
          RestartSec = 5;
          LoadCredential = [
            "qcore-credentials:${cfg.credentialsFile}"
            "mqtt-password:${cfg.mqttPasswordFile}"
          ];
          RuntimeDirectory = "qendercore-mqtt";
          RuntimeDirectoryMode = "0700";
          StateDirectory = "qendercore-mqtt";
          StateDirectoryMode = "0700";
          DynamicUser = true;
        };
      };
    })
  ]);
}
