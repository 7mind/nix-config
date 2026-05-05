{ config, lib, pkgs, cfg-meta, ... }:

let
  cfg = config.smind.monitoring.gatus;

  mkAlertSpec = type: {
    inherit type;
    failure-threshold = 3;
    success-threshold = 2;
    send-on-resolved = true;
    description = "service degraded";
  };

  mkAlerts =
    [ (mkAlertSpec "email") ]
    ++ lib.optional cfg.matrix.enable (mkAlertSpec "matrix");

  # status: a gatus condition fragment for the [STATUS] variable, e.g.
  #   "< 400"                  — anything non-error
  #   "== 200"                 — strict success
  #   "== any(200, 401)"       — auth-protected service that returns 401 unauthenticated
  # maxResponseMs: pass `null` to skip the response-time check entirely
  # (e.g. for heavy dashboards that legitimately take seconds to render).
  mkHttp = { name, group, url, status ? "< 400", interval ? "60s", maxResponseMs ? 5000, insecure ? false }: {
    inherit name group url interval;
    conditions =
      [ "[STATUS] ${status}" ]
      ++ lib.optional (maxResponseMs != null) "[RESPONSE_TIME] < ${toString maxResponseMs}";
    alerts = mkAlerts;
  } // lib.optionalAttrs insecure {
    client = { insecure = true; };
  };

  hostName = config.networking.hostName;

  # Cross-host gatus probes: each instance probes the *other* gatus, so a dead
  # monitor surfaces in the surviving one.
  gatusPeers = [
    { name = "Gatus (vm)";      group = "monitoring"; host = "vm";      url = "http://vm.home.7mind.io:8484/"; }
    { name = "Gatus (raspi5m)"; group = "monitoring"; host = "raspi5m"; url = "http://raspi5m.home.7mind.io:8484/"; }
  ];
  peerEndpoints =
    map (p: mkHttp { inherit (p) name group url; })
      (lib.filter (p: p.host != hostName) gatusPeers);

  endpoints = peerEndpoints ++ [
    # nginx alive check — internal vhost returns 404 on / by design.
    # rejectSSL=true on this vhost, so probe over http.
    (mkHttp { name = "edge: nginx 404"; group = "edge"; url = "http://nginx.web.7mind.io/"; status = "== 404"; })

    # Internal HTTP services on vm — probed by internal hostname so that nginx
    # IP/oauth gates don't mask backend failures.
    (mkHttp { name = "Home Assistant"; group = "vm-services"; url = "http://ha.home.7mind.io:8123/"; })
    (mkHttp { name = "Jellyfin";       group = "vm-services"; url = "http://jellyfin.home.7mind.io/"; })
    (mkHttp { name = "Grafana";        group = "vm-services"; url = "http://grafana.web.7mind.io/"; })
    (mkHttp { name = "vpn-services (todo)"; group = "vm-services"; url = "http://vpn-services.web.7mind.io/"; })
    (mkHttp { name = "Torrent UI";     group = "vm-services"; url = "http://torrent.home.7mind.io/"; })
    # Probe the readiness endpoint, not the UI — cheap, doesn't touch TSDB.
    (mkHttp { name = "Prometheus";     group = "vm-services"; url = "http://prometheus.web.7mind.io/-/ready"; })
    (mkHttp { name = "InfluxDB";       group = "vm-services"; url = "http://influx.home.7mind.io/"; })
    (mkHttp { name = "Atuin";          group = "vm-services"; url = "http://atuin.home.7mind.io/"; })
    (mkHttp { name = "Syncthing P UI"; group = "vm-services"; url = "http://syncp.home.7mind.io/"; })
    (mkHttp { name = "BentoPDF";       group = "vm-services"; url = "http://bentopdf.web.7mind.io/"; })
    # Transmission RPC requires auth — 401 unauthenticated is the healthy state.
    (mkHttp { name = "Transmission 1"; group = "vm-services"; url = "http://transmission1.pgtr.7mind.io/"; status = "== any(200, 401)"; })
    (mkHttp { name = "Transmission 2"; group = "vm-services"; url = "http://transmission2.pgtr.7mind.io/"; status = "== any(200, 401)"; })

    # Internal services on raspi5m
    (mkHttp { name = "Glance dashboard"; group = "raspi5m"; url = "http://glance.home.7mind.io/"; })
    (mkHttp { name = "Zigbee2MQTT";      group = "raspi5m"; url = "http://raspi5m.home.7mind.io:8080/"; })
    (mkHttp { name = "Z-Wave JS UI";     group = "raspi5m"; url = "http://raspi5m.home.7mind.io:8091/"; })
    (mkHttp { name = "MQTT Driver";      group = "raspi5m"; url = "http://raspi5m.home.7mind.io:8780/"; })

    # Network / infra
    # Unifi controller redirects http→https and uses a self-signed cert.
    (mkHttp { name = "Unifi controller"; group = "infra"; url = "https://unifi.home.7mind.io/"; insecure = true; })
    # Supermicro BMC — self-signed cert; landing page redirects (302).
    (mkHttp { name = "Supermicro BMC";   group = "infra"; url = "https://sm.home.7mind.io/"; insecure = true; status = "== any(200, 302)"; })
    # Browser container UI on raspi5m.
    (mkHttp { name = "Browser";          group = "infra"; url = "http://browser.home.7mind.io/"; })

    # IoT / collar device
    (mkHttp { name = "Collars web UI";  group = "iot"; url = "http://collars.iot-lan.7mind.io/"; })
    (mkHttp { name = "Energy Driver";   group = "iot"; url = "http://victron.iot-lan.7mind.io:8910/"; })
    # Victron Cerbo web console — self-signed cert.
    (mkHttp { name = "Victron Console"; group = "iot"; url = "https://victron.iot-lan.7mind.io/"; insecure = true; })
    # Node-RED on the Victron Cerbo — self-signed cert on :1881.
    (mkHttp { name = "Node-RED";        group = "iot"; url = "https://victron.iot-lan.7mind.io:1881/"; insecure = true; })
    # Printer's web UI redirects (301).
    (mkHttp { name = "Printer";         group = "iot"; url = "http://printer.iot-lan.7mind.io/"; status = "== any(200, 301)"; })
    # Siemens alarm panel.
    (mkHttp { name = "Alarm panel";     group = "iot"; url = "http://alarm.iot-lan.7mind.io/"; })
    # RS485 gateway requires auth — 401 unauthenticated is healthy.
    (mkHttp { name = "RS485 gateway";   group = "iot"; url = "http://rs485.iot-lan.7mind.io/"; status = "== any(200, 401)"; })
    # Zyxel NR7101 5G modem — local IP only, self-signed if redirected to https.
    (mkHttp { name = "Zyxel NR7101 5G"; group = "iot"; url = "http://192.168.2.1/"; insecure = true; })

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
