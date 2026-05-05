{ config, lib, pkgs, cfg-meta, ... }:

let
  cfg = config.smind.monitoring.gatus;

  mkAlertSpec = type: {
    inherit type;
    failure-threshold = 2;
    success-threshold = 2;
    send-on-resolved = true;
    description = "service degraded";
  };

  mkAlerts =
    [ (mkAlertSpec "email") ]
    ++ lib.optional cfg.matrix.enable (mkAlertSpec "matrix");

  # Per-group probe cadence. Critical / fast-moving groups get 30s so we
  # catch outages quickly; everything else stays at 60s.
  fastGroups = [ "edge" "iot-core" "network" "energy" ];
  intervalForGroup = group:
    if builtins.elem group fastGroups then "30s" else "60s";

  # status: a gatus condition fragment for the [STATUS] variable, e.g.
  #   "< 400"                  — anything non-error
  #   "== 200"                 — strict success
  #   "== any(200, 401)"       — auth-protected service that returns 401 unauthenticated
  # maxResponseMs: pass `null` to skip the response-time check entirely
  # (e.g. for heavy dashboards that legitimately take seconds to render).
  # interval: omit to use the per-group default (intervalForGroup).
  mkHttp = { name, group, url, status ? "< 400", interval ? null, maxResponseMs ? 5000, insecure ? false }: {
    inherit name group url;
    interval = if interval != null then interval else intervalForGroup group;
    # [CONNECTED] guards against DNS / refused / TLS / timeout failures —
    # without it, [STATUS] defaults to 0 on transport errors and `< 400`
    # silently passes on a dead host.
    conditions =
      [ "[CONNECTED] == true" "[STATUS] ${status}" ]
      ++ lib.optional (maxResponseMs != null) "[RESPONSE_TIME] < ${toString maxResponseMs}";
    alerts = mkAlerts;
  } // lib.optionalAttrs insecure {
    client = { insecure = true; };
  };

  hostName = config.networking.hostName;

  # Cross-host gatus probes: each instance probes the *other* gatus, so a dead
  # monitor surfaces in the surviving one.
  gatusPeers = [
    { name = "Gatus (vm)";      group = "edge"; host = "vm";      url = "http://vm.home.7mind.io:8484/"; }
    { name = "Gatus (raspi5m)"; group = "edge"; host = "raspi5m"; url = "http://raspi5m.home.7mind.io:8484/"; }
  ];
  peerEndpoints =
    map (p: mkHttp { inherit (p) name group url; })
      (lib.filter (p: p.host != hostName) gatusPeers);

  endpoints = peerEndpoints ++ [
    # ── edge ────────────────────────────────────────────────────────────────
    # nginx alive check — internal vhost returns 404 on / by design.
    # rejectSSL=true on this vhost, so probe over http.
    (mkHttp { name = "nginx 404"; group = "edge"; url = "http://nginx.web.7mind.io/"; status = "== 404"; })

    # ── observability ───────────────────────────────────────────────────────
    # Probe the readiness endpoint, not the UI — cheap, doesn't touch TSDB.
    (mkHttp { name = "Prometheus"; group = "observability"; url = "http://prometheus.web.7mind.io/-/ready"; })
    (mkHttp { name = "Grafana";    group = "observability"; url = "http://grafana.web.7mind.io/"; })
    (mkHttp { name = "InfluxDB";   group = "observability"; url = "http://influx.home.7mind.io/"; })

    # ── iot-core ────────────────────────────────────────────────────────────
    (mkHttp { name = "Home Assistant"; group = "iot-core"; url = "http://ha.home.7mind.io:8123/"; })
    (mkHttp { name = "MQTT Driver";    group = "iot-core"; url = "http://raspi5m.home.7mind.io:8780/"; })
    (mkHttp { name = "Zigbee2MQTT";    group = "iot-core"; url = "http://raspi5m.home.7mind.io:8080/"; })
    (mkHttp { name = "Z-Wave JS UI";   group = "iot-core"; url = "http://raspi5m.home.7mind.io:8091/"; })

    # ── iot-devices ─────────────────────────────────────────────────────────
    (mkHttp { name = "Collars web UI"; group = "iot-devices"; url = "http://collars.iot-lan.7mind.io/"; })
    # Siemens alarm panel.
    (mkHttp { name = "Alarm panel";    group = "iot-devices"; url = "http://alarm.iot-lan.7mind.io/"; })
    # RS485 gateway requires auth — 401 unauthenticated is healthy.
    (mkHttp { name = "RS485 gateway";  group = "iot-devices"; url = "http://rs485.iot-lan.7mind.io/"; status = "== any(200, 401)"; })
    # Printer's web UI redirects (301).
    (mkHttp { name = "Printer";        group = "iot-devices"; url = "http://printer.iot-lan.7mind.io/"; status = "== any(200, 301)"; })

    # ── energy (Victron Cerbo subsystem) ────────────────────────────────────
    (mkHttp { name = "Energy Driver";   group = "energy"; url = "http://victron.iot-lan.7mind.io:8910/"; })
    # Victron Cerbo web console — self-signed cert.
    (mkHttp { name = "Victron Console"; group = "energy"; url = "https://victron.iot-lan.7mind.io/"; insecure = true; })
    # Node-RED on the Victron Cerbo — self-signed cert on :1881.
    (mkHttp { name = "Node-RED";        group = "energy"; url = "https://victron.iot-lan.7mind.io:1881/"; insecure = true; })

    # ── media ───────────────────────────────────────────────────────────────
    (mkHttp { name = "Jellyfin";       group = "media"; url = "http://jellyfin.home.7mind.io/"; })
    (mkHttp { name = "Torrent UI";     group = "media"; url = "http://torrent.home.7mind.io/"; })
    # Transmission RPC requires auth — 401 unauthenticated is the healthy state.
    (mkHttp { name = "Transmission 1"; group = "media"; url = "http://transmission1.pgtr.7mind.io/"; status = "== any(200, 401)"; })
    (mkHttp { name = "Transmission 2"; group = "media"; url = "http://transmission2.pgtr.7mind.io/"; status = "== any(200, 401)"; })

    # ── tools ───────────────────────────────────────────────────────────────
    (mkHttp { name = "Atuin";            group = "tools"; url = "http://atuin.home.7mind.io/"; })
    (mkHttp { name = "BentoPDF";         group = "tools"; url = "http://bentopdf.web.7mind.io/"; })
    (mkHttp { name = "Browser";          group = "tools"; url = "http://browser.home.7mind.io/"; })
    (mkHttp { name = "Syncthing P UI";   group = "tools"; url = "http://syncp.home.7mind.io/"; })
    (mkHttp { name = "Glance dashboard"; group = "tools"; url = "http://glance.home.7mind.io/"; })
    # `vpn-services` is the legacy container name; serves the Todo app.
    (mkHttp { name = "Todo"; group = "tools"; url = "http://vpn-services.web.7mind.io/"; })

    # ── network (gear / platform hardware) ──────────────────────────────────
    # Unifi controller redirects http→https and uses a self-signed cert.
    (mkHttp { name = "Unifi controller"; group = "network"; url = "https://unifi.home.7mind.io/"; insecure = true; })
    # Zyxel NR7101 5G modem — local IP only, self-signed if redirected to https.
    (mkHttp { name = "Zyxel NR7101 5G";  group = "network"; url = "http://192.168.2.1/"; insecure = true; })
    # Supermicro BMC — self-signed cert; landing page redirects (302).
    (mkHttp { name = "Supermicro BMC";   group = "network"; url = "https://sm.home.7mind.io/"; insecure = true; status = "== any(200, 302)"; })

    # No tor probe — its traffic is isolated from the host network, so a TCP
    # probe from gatus would only show false negatives. Tor's own self-test
    # (logged via the tor relay) is the right monitor for that.

    # No AmneziaWG probe — UDP-only, and gatus can't usefully probe an
    # encrypted-handshake-required port from outside the VPN.
  ];
in
{
  options.smind.monitoring.gatus = {
    enable = lib.mkEnableOption "gatus uptime monitoring with email alerts";

    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Address gatus binds its dashboard to.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8484;
      description = "Port gatus serves its dashboard on.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the firewall for the gatus dashboard.";
    };

    matrix = {
      enable = lib.mkEnableOption "matrix alerts (in addition to email)";

      serverUrl = lib.mkOption {
        type = lib.types.str;
        example = "https://matrix.example.org";
        description = "Matrix homeserver URL for the bot account.";
      };

      roomId = lib.mkOption {
        type = lib.types.str;
        example = "!abcdef:matrix.example.org";
        description = "Internal room ID (the !id form, not #alias) where alerts are posted.";
      };

      tokenSecret = lib.mkOption {
        type = lib.types.str;
        default = "gatus-matrix-token";
        description = ''
          Name of the agenix secret holding the bot's access token (raw value).
          The secret must be declared elsewhere via age.secrets.<name> with mode 0444
          (or readable by gatus's service user).
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.smind.host.email.enable;
        message = "smind.monitoring.gatus.enable requires smind.host.email.enable for SMTP credentials.";
      }
    ];

    services.gatus = {
      enable = true;
      settings = {
        web = {
          address = cfg.bindAddress;
          port = cfg.port;
        };
        alerting = {
          email = {
            from = "monitor.${config.networking.hostName}.${config.smind.host.email.sender}";
            username = "7mind.io";
            password = "\${SMTP_PASSWORD}";
            host = "mail.smtp2go.com";
            port = 587;
            to = config.smind.host.email.to;
          };
        } // lib.optionalAttrs cfg.matrix.enable {
          matrix = {
            server-url = cfg.matrix.serverUrl;
            access-token = "\${MATRIX_TOKEN}";
            internal-room-id = cfg.matrix.roomId;
          };
        };
        inherit endpoints;
      };
    };

    age.secrets = lib.mkIf cfg.matrix.enable {
      ${cfg.matrix.tokenSecret} = {
        rekeyFile = "${cfg-meta.paths.secrets}/generic/${cfg.matrix.tokenSecret}.age";
        mode = "444";
      };
    };

    # Compose gatus's env file from one or more agenix secrets each service start.
    # All referenced secrets are world-readable (mode 0444), so gatus's static or
    # DynamicUser can read them without extra permission grants.
    systemd.services.gatus.serviceConfig = {
      RuntimeDirectory = "gatus";
      RuntimeDirectoryMode = "0750";
      EnvironmentFile = "-/run/gatus/env";
      ExecStartPre = pkgs.writeShellScript "gatus-env" ''
        set -euo pipefail
        umask 0137
        {
          printf 'SMTP_PASSWORD=%s\n' "$(cat ${config.age.secrets.msmtp-password.path})"
          ${lib.optionalString cfg.matrix.enable ''
            printf 'MATRIX_TOKEN=%s\n' "$(cat ${config.age.secrets.${cfg.matrix.tokenSecret}.path})"
          ''}
        } > /run/gatus/env
      '';
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
