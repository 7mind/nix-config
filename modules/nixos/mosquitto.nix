{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.mosquitto;
  bridge = cfg.bridge;
  token = lib.types.strMatching "[^[:space:]]+";
  line = lib.types.strMatching "[^\r\n]+";
  bridgeTemplate = pkgs.writeText "mosquitto-bridge.conf.in" ''
    connection ${bridge.name}
    address ${bridge.address}:${toString bridge.port}
    remote_username ${bridge.username}
    remote_password @PASSWORD@
    bridge_protocol_version ${bridge.protocolVersion}
    cleansession ${lib.boolToString bridge.cleanSession}
    try_private ${lib.boolToString bridge.tryPrivate}
    notifications ${lib.boolToString bridge.notifications}
    restart_timeout ${bridge.restartTimeout}
    keepalive_interval ${toString bridge.keepaliveInterval}
    max_queued_messages ${toString bridge.maxQueuedMessages}
    ${lib.concatMapStringsSep "\n" (topic: "topic ${topic}") bridge.topics}
  '';
in
{
  options = {
    smind.services.mosquitto = {
      enable = lib.mkEnableOption "Mosquitto MQTT broker";
      bridge = lib.mkOption {
        default = null;
        description = "Optional runtime-authenticated bridge, independent of the managed listener.";
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = token;
              description = "Mosquitto connection name.";
            };
            address = lib.mkOption {
              type = token;
              description = "Remote broker address (bracket IPv6 addresses).";
            };
            port = lib.mkOption {
              type = lib.types.port;
              default = 1883;
              description = "Remote broker port.";
            };
            username = lib.mkOption {
              type = line;
              description = "Remote MQTT username.";
            };
            passwordFile = lib.mkOption {
              type = lib.types.strMatching "/[^\r\n]+";
              description = "Absolute runtime path to a password file; never read during evaluation. A trailing newline is stripped; embedded newlines and NUL bytes are rejected.";
            };
            topics = lib.mkOption {
              type = lib.types.listOf line;
              description = "Mosquitto topic rules, including direction, QoS and optional prefixes.";
              example = [ "telemetry/# out 1" "commands/# in 1" ];
            };
            protocolVersion = lib.mkOption {
              type = lib.types.enum [ "mqttv31" "mqttv311" "mqttv50" ];
              default = "mqttv311";
              description = "Remote MQTT protocol version.";
            };
            cleanSession = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Clear remote session on reconnect.";
            };
            tryPrivate = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Identify the connection as a bridge to the remote broker.";
            };
            notifications = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Publish bridge connection notifications.";
            };
            restartTimeout = lib.mkOption {
              type = lib.types.strMatching "[0-9]+( [0-9]+)?";
              default = "5 60";
              description = "Reconnect timeout, or base and cap for jittered backoff (seconds).";
            };
            keepaliveInterval = lib.mkOption {
              type = lib.types.ints.positive;
              default = 30;
              description = "Bridge keepalive interval in seconds.";
            };
            maxQueuedMessages = lib.mkOption {
              type = lib.types.ints.unsigned;
              default = 100000;
              description = "Broker-wide queued QoS 1/2 message limit (zero means unlimited).";
            };
            runtimeDirectory = lib.mkOption {
              type = lib.types.strMatching "/run/[a-zA-Z0-9_-]+";
              default = "/run/mosquitto-bridge";
              description = "Protected directory for the generated bridge include.";
            };
            rendererUnit = lib.mkOption {
              type = lib.types.strMatching "[a-zA-Z0-9_-]+";
              default = "mosquitto-bridge";
              description = "Name of the oneshot renderer systemd service (without suffix).";
            };
          };
        });
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 1883;
        description = "The port for the MQTT broker.";
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "mqtt";
        description = "MQTT username.";
      };
      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to the file containing the MQTT password.";
      };
    };
  };

  config = lib.mkMerge [ (lib.mkIf cfg.enable {
    services.mosquitto = {
      enable = true;
      settings = {
        # 0 = unlimited; z2m retained messages can exceed ~200KB.
        message_size_limit = 0;
      };
      listeners = [
        {
          port = cfg.port;
          acl = [ "topic readwrite #" ];
          users.${cfg.user} = {
            passwordFile = cfg.passwordFile;
            acl = [ "readwrite #" ];
          };
        }
      ];
    };

    environment.systemPackages = [ pkgs.mosquitto ];

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  }) (lib.mkIf (bridge != null) {
    services.mosquitto = {
      enable = true;
      includeDirs = [ bridge.runtimeDirectory ];
    };

    systemd.tmpfiles.rules = [
      "d ${bridge.runtimeDirectory} 0750 mosquitto mosquitto -"
    ];

    systemd.services.${bridge.rendererUnit} = {
      description = "Render runtime-authenticated Mosquitto bridge configuration";
      requiredBy = [ "mosquitto.service" ];
      before = [ "mosquitto.service" ];
      # Allow first boot before the caller has enrolled the runtime secret.
      unitConfig.ConditionPathExists = bridge.passwordFile;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
      };
      script = ''
        set -euo pipefail
        install -d -m 0750 -o mosquitto -g mosquitto ${lib.escapeShellArg bridge.runtimeDirectory}
        ${pkgs.python3}/bin/python3 - ${lib.escapeShellArg bridge.passwordFile} ${bridgeTemplate} ${lib.escapeShellArg bridge.runtimeDirectory} <<'PYTHON'
        import os
        import pathlib
        import pwd
        import sys
        import tempfile

        password_file, template_file, directory = sys.argv[1:]
        password = pathlib.Path(password_file).read_bytes().rstrip(b"\n")
        if not password or any(c in password for c in (b"\n", b"\r", b"\0")):
            raise SystemExit("Invalid Mosquitto bridge password: expected a nonempty single line")
        content = pathlib.Path(template_file).read_bytes().replace(b"\nremote_password @PASSWORD@\n", b"\nremote_password " + password + b"\n", 1)
        owner = pwd.getpwnam("mosquitto")
        fd, temporary = tempfile.mkstemp(prefix=".upstream-", dir=directory)
        try:
            with os.fdopen(fd, "wb") as output:
                output.write(content)
                output.flush()
                os.fchown(output.fileno(), owner.pw_uid, owner.pw_gid)
                os.fchmod(output.fileno(), 0o640)
            os.replace(temporary, os.path.join(directory, "upstream.conf"))
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        PYTHON
      '';
    };
  }) ];
}
