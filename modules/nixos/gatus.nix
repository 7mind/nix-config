{ config, lib, pkgs, cfg-meta, ... }:

let
  cfg = config.smind.monitoring.gatus;

  mkAlerts = [{
    type = "email";
    failure-threshold = 3;
    success-threshold = 2;
    send-on-resolved = true;
    description = "service degraded";
  }];

  # status: a gatus condition fragment for the [STATUS] variable, e.g.
  #   "< 400"             — anything non-error
  #   "== 200"            — strict success
  #   "in (200, 401)"     — auth-protected service that returns 401 unauthenticated
  # maxResponseMs: pass `null` to skip the response-time check entirely
  # (e.g. for heavy dashboards that legitimately take seconds to render).
  mkHttp = { name, group, url, status ? "< 400", interval ? "60s", maxResponseMs ? 5000 }: {
    inherit name group url interval;
    conditions =
      [ "[STATUS] ${status}" ]
      ++ lib.optional (maxResponseMs != null) "[RESPONSE_TIME] < ${toString maxResponseMs}";
    alerts = mkAlerts;
  };

  endpoints = [
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
    (mkHttp { name = "Prometheus";     group = "vm-services"; url = "http://prometheus-web.web.7mind.io/"; })
    (mkHttp { name = "InfluxDB";       group = "vm-services"; url = "http://influx.home.7mind.io/"; })
    (mkHttp { name = "Atuin";          group = "vm-services"; url = "http://atuin.home.7mind.io/"; })
    (mkHttp { name = "Syncplay UI";    group = "vm-services"; url = "http://syncp.home.7mind.io/"; })
    (mkHttp { name = "BentoPDF";       group = "vm-services"; url = "http://bentopdf.web.7mind.io/"; })
    # Transmission RPC requires auth — 401 unauthenticated is the healthy state.
    (mkHttp { name = "Transmission 1"; group = "vm-services"; url = "http://transmission1.pgtr.7mind.io/"; status = "in (200, 401)"; })
    (mkHttp { name = "Transmission 2"; group = "vm-services"; url = "http://transmission2.pgtr.7mind.io/"; status = "in (200, 401)"; })

    # Internal services on raspi5m
    (mkHttp { name = "Glance dashboard"; group = "raspi5m"; url = "http://glance.home.7mind.io/"; })
    (mkHttp { name = "Zigbee2MQTT";      group = "raspi5m"; url = "http://raspi5m.home.7mind.io:8080/"; })
    (mkHttp { name = "Z-Wave JS UI";     group = "raspi5m"; url = "http://raspi5m.home.7mind.io:8091/"; })

    # IoT / collar device
    (mkHttp { name = "Collars web UI"; group = "iot"; url = "http://collars.iot-lan.7mind.io/"; })

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
        alerting.email = {
          from = "monitor.${config.networking.hostName}.${config.smind.host.email.sender}";
          username = "7mind.io";
          password = "\${SMTP_PASSWORD}";
          host = "mail.smtp2go.com";
          port = 587;
          to = config.smind.host.email.to;
        };
        inherit endpoints;
      };
    };

    # Reuse the existing msmtp-password secret (raw password value) — wrap it
    # into KEY=VALUE form for gatus's EnvironmentFile each time the service
    # starts. msmtp-password.age is world-readable (mode 0444), so gatus's
    # service user — static or DynamicUser — can read it without further
    # permission grants.
    systemd.services.gatus.serviceConfig = {
      RuntimeDirectory = "gatus";
      RuntimeDirectoryMode = "0750";
      EnvironmentFile = "-/run/gatus/smtp-env";
      ExecStartPre = pkgs.writeShellScript "gatus-smtp-env" ''
        set -euo pipefail
        umask 0137
        printf 'SMTP_PASSWORD=%s\n' "$(cat ${config.age.secrets.msmtp-password.path})" > /run/gatus/smtp-env
      '';
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
