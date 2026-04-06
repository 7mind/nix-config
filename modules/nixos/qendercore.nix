{ config, lib, pkgs, cfg-flakes, cfg-meta, ... }:

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
in
{
  options = {
    smind.services.qendercore = {
      enable = lib.mkEnableOption "Qendercore MQTT adapter";
      credentialsFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to the JSON file with Qendercore login and password.";
      };
      mqttHost = lib.mkOption {
        type = lib.types.str;
        description = "MQTT broker hostname.";
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

  config = lib.mkIf cfg.enable {
    systemd.services.qendercore-mqtt = {
      description = "Qendercore MQTT adapter";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${qendercoreMqttRunner}";
        Restart = "always";
      };
    };
  };
}
