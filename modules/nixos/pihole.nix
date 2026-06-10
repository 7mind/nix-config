{ config, lib, ... }:

let
  cfg = config.smind.services.pihole;
  netCfg = config.smind.net;

  # The bridge interfaces this host exposes (main bridge + any bridged VLANs).
  # DNS and the web UI are reachable only on these.
  bridgeIfaces =
    lib.optional netCfg.bridge.enable netCfg.main-bridge
    ++ lib.mapAttrsToList (_: v: v.bridge.name)
      (lib.filterAttrs (_: v: v.bridge.enable) netCfg.vlans);
in
{
  options = {
    smind.services.pihole = {
      enable = lib.mkEnableOption "Pi-hole network-wide DNS";

      interfaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = bridgeIfaces;
        defaultText = lib.literalExpression "the host's bridge interfaces";
        description = ''
          Interfaces pihole-FTL binds its DNS listener to, on BOTH IPv4 and
          IPv6. pihole-FTL (a dnsmasq fork) cannot bind a wildcard here without
          colliding with systemd-resolved's stub listener on 127.0.0.53:53, and
          its built-in single-interface modes (SINGLE/BIND) cannot cover more
          than one bridge. We therefore set listeningMode = "NONE" and drive the
          bind from misc.dnsmasq_lines with `bind-dynamic`: each listed
          interface is bound on every address it has (v4 + v6), loopback is left
          untouched (so resolved keeps 127.0.0.53), and addresses assigned later
          (e.g. the DHCP-reserved lease) are picked up without a restart.
        '';
        example = [ "br-infra" ];
      };

      webPort = lib.mkOption {
        type = lib.types.port;
        # Mirrors the port the AdGuard module used here; 3000 is taken by
        # zwave-js-server on this host class.
        default = 3001;
        description = "Web admin interface port (bound on the same interfaces).";
      };

      upstreams = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        # Cloudflare (v4 + v6). Pi-hole's NixOS config is immutable, so unlike
        # the AdGuard web UI upstreams are declarative; this is a sane default
        # that hosts can override.
        default = [
          "1.1.1.1"
          "1.0.0.1"
          "2606:4700:4700::1111"
          "2606:4700:4700::1001"
        ];
        description = ''
          Upstream DNS servers Pi-hole forwards to. Each entry is an IP,
          optionally with `#port` (e.g. "127.0.0.1#5335").
        '';
      };

      lists = lib.mkOption {
        type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
        # HaGeZi Pro (balanced ad/tracker/privacy, low false positives) plus the
        # orthogonal Threat Intelligence Feeds (malware/phishing/scam) — the one
        # stacking HaGeZi recommends. Deliberately NOT combined with other big
        # meta-lists (OISD/StevenBlack): redundant, and each adds false-positive
        # surface.
        default = [
          {
            url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/pro.txt";
            description = "HaGeZi Pro — ads/trackers/privacy";
          }
          {
            url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/tif.txt";
            description = "HaGeZi Threat Intelligence Feeds";
          }
        ];
        description = ''
          Adlists passed through to services.pihole-ftl.lists (loaded into the
          mutable gravity database on startup via the web API).
        '';
      };

      conditionalForwarding = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether this conditional-forwarding entry is active.";
            };
            ipRange = lib.mkOption {
              type = lib.types.str;
              description = "Reverse zone in CIDR, e.g. \"192.168.10.0/24\".";
              example = "192.168.10.0/24";
            };
            target = lib.mkOption {
              type = lib.types.str;
              description = "Server to forward to, optionally with #port, e.g. \"192.168.10.1\".";
              example = "192.168.10.1";
            };
            domain = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = ''
                Optional forward domain. When set, forward lookups for this
                domain AND its subdomains are also sent to `target`
                (dnsmasq `server=/<domain>/<target>`).
              '';
              example = "7mind.io";
            };
          };
        });
        default = [ ];
        description = ''
          Conditional forwarding (Pi-hole revServers / dnsmasq rev-server).
          Each entry forwards reverse PTR lookups for `ipRange` to `target`,
          and — if `domain` is set — also forwards forward lookups for `domain`
          and its subdomains to `target`. A rev-server route takes precedence
          over `bogusPriv` for the zone it covers (dnsmasq >= 2.77), so private
          reverse names resolve while `bogusPriv` still protects every range not
          listed here; there is no need to disable `bogusPriv`.
        '';
        example = [{ ipRange = "192.168.10.0/24"; target = "192.168.10.1"; domain = "7mind.io"; }];
      };

      webPasswordHash = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Pi-hole web/API password hash (webserver.api.pwhash), as produced by
          `pihole-FTL --pwhash`. When empty the admin UI requires no password;
          it is reachable only on `interfaces` (LAN bridges). NOTE: a value set
          here is written into the world-readable Nix store — use a throwaway
          hash, not a reused secret.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.interfaces != [ ];
        message = "smind.services.pihole.interfaces must list the interfaces to bind DNS to.";
      }
    ];

    services.pihole-ftl = {
      enable = true;
      # Open nothing globally; the per-interface rules below scope DNS + the web
      # UI to the LAN bridges only (mirroring the previous AdGuard exposure).
      openFirewallDNS = false;
      openFirewallDHCP = false;
      openFirewallWebserver = false;

      lists = cfg.lists;

      settings = {
        dns = {
          listeningMode = "NONE"; # bind is driven manually below — see `interfaces`.
          upstreams = cfg.upstreams;
          # Conditional forwarding. bogusPriv is intentionally left at its
          # default (true); rev-server routes win over it for the listed zones.
          revServers = map
            (e: "${lib.boolToString e.enable},${e.ipRange},${e.target}"
              + lib.optionalString (e.domain != "") ",${e.domain}")
            cfg.conditionalForwarding;
        };

        # No DHCP server: Pi-hole is DNS-only here.
        dhcp.active = false;

        # Manual multi-interface bind (see the `interfaces` option doc).
        # `except-interface=lo` is REQUIRED: with `interface=`, dnsmasq always
        # auto-adds the loopback interface (dnsmasq.8), so it would try to bind
        # [::1]:53 — which systemd-resolved's stub listener already holds — and
        # the failed bind is fatal ("FAILED to start up"), taking the whole DNS
        # listener down. Excluding lo leaves resolved's 127.0.0.53 / [::1] alone.
        misc.dnsmasq_lines =
          (map (i: "interface=${i}") cfg.interfaces)
          ++ [ "except-interface=lo" "bind-dynamic" ];

        # The upstream module hardens the unit with ProtectSystem=strict but
        # provisions no writable runtime dir, so FTL cannot write its default
        # /run/pihole-FTL.pid ("Permission denied"). Point it at a systemd-
        # managed RuntimeDirectory (created writable for User=pihole, cleared on
        # stop) — see the RuntimeDirectory override below.
        files.pid = "/run/pihole-FTL/pihole-FTL.pid";

        webserver.api = {
          # Ephemeral CLI password so the lists setup script can authenticate
          # against the local API to load adlists.
          cli_pw = true;
        } // lib.optionalAttrs (cfg.webPasswordHash != "") {
          pwhash = cfg.webPasswordHash;
        };
      };
    };

    services.pihole-web = {
      enable = true;
      ports = [ (toString cfg.webPort) ];
    };

    # Writable /run/pihole-FTL for the PID file (see settings.files.pid above).
    systemd.services.pihole-ftl.serviceConfig.RuntimeDirectory = "pihole-FTL";

    # Expose DNS (53 tcp+udp) and the web UI only on the chosen interfaces.
    networking.firewall.interfaces = lib.genAttrs cfg.interfaces (_: {
      allowedTCPPorts = [ 53 cfg.webPort ];
      allowedUDPPorts = [ 53 ];
    });
  };
}
