{ config, lib, ... }:

let
  cfg = config.smind.services.adguard;
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
    smind.services.adguard = {
      enable = lib.mkEnableOption "AdGuard Home network-wide DNS";

      dnsBindHosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = ''
          IP addresses AdGuard binds its DNS listener to. Bind to the host's
          static bridge addresses, NOT 0.0.0.0: a wildcard bind collides with
          systemd-resolved's stub listener on 127.0.0.53:53. Binding specific
          bridge IPs leaves the loopback DNS port to resolved untouched.
        '';
        example = [ "192.168.10.250" ];
      };

      dnsPort = lib.mkOption {
        type = lib.types.port;
        default = 53;
        description = "DNS listener port.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        # Not the upstream default (3000): that is taken by zwave-js-server.
        default = 3001;
        description = "Web admin interface port.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.dnsBindHosts != [ ];
        message = "smind.services.adguard.dnsBindHosts must list the static bridge addresses to bind DNS to.";
      }
      {
        assertion = bridgeIfaces != [ ];
        message = "smind.services.adguard requires bridge interfaces to expose DNS on; none are configured in smind.net.";
      }
    ];

    services.adguardhome = {
      enable = true;
      # Filter lists, upstreams and the admin password are configured in the
      # web UI and persist across restarts; only the keys below are merged in
      # (and enforced) on every start.
      mutableSettings = true;
      port = cfg.port;
      settings.dns = {
        bind_hosts = cfg.dnsBindHosts;
        port = cfg.dnsPort;
      };
    };

    # Binding a specific bridge IP can race the DHCP lease at boot (the unit
    # orders only after network.target). Allow binding an address that is not
    # configured yet so the listener never fails to start.
    boot.kernel.sysctl = {
      "net.ipv4.ip_nonlocal_bind" = 1;
      "net.ipv6.ip_nonlocal_bind" = 1;
    };

    # Expose DNS (53 tcp+udp) and the web UI only on the bridge interfaces.
    networking.firewall.interfaces = lib.genAttrs bridgeIfaces (_: {
      allowedTCPPorts = [ cfg.dnsPort cfg.port ];
      allowedUDPPorts = [ cfg.dnsPort ];
    });
  };
}
