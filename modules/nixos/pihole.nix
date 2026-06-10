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
        default = [
          {
            url = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";
            description = "Steven Black's unified adlist";
          }
        ];
        description = ''
          Adlists passed through to services.pihole-ftl.lists (loaded into the
          mutable gravity database on startup via the web API).
        '';
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
        };

        # No DHCP server: Pi-hole is DNS-only here.
        dhcp.active = false;

        # Manual multi-interface bind (see the `interfaces` option doc).
        misc.dnsmasq_lines =
          (map (i: "interface=${i}") cfg.interfaces) ++ [ "bind-dynamic" ];

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

    # Expose DNS (53 tcp+udp) and the web UI only on the chosen interfaces.
    networking.firewall.interfaces = lib.genAttrs cfg.interfaces (_: {
      allowedTCPPorts = [ 53 cfg.webPort ];
      allowedUDPPorts = [ 53 ];
    });
  };
}
