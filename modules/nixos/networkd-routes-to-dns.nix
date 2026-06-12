{ lib, ... }:

# Repo-wide default: disable systemd-networkd's RoutesToDNS on every DHCPv4
# network.
#
# RoutesToDNS (networkd's default: true) installs a /32 route to each
# DHCP-advertised DNS server via that lease's gateway. On a multi-homed host
# this hijacks ALL traffic to those IPs onto the wrong uplink. Concretely on
# `vm`: the br-web (192.168.42.x) lease advertises the Pi-holes
# (192.168.10.250/.251) as DNS, so networkd pinned
#   192.168.10.250/.251 via 192.168.42.1 dev br-web
# which shadowed the correct on-link br-infra routes and broke vm -> raspi5m/
# raspi5l (incl. the nginx reverse proxies).
#
# The route is only load-bearing when a resolver is reachable SOLELY via its
# lease's gateway — not the case on any host here. Single-homed hosts route
# everything via their one default route regardless, so disabling is a no-op
# for them. mkDefault, so a specific network can still re-enable it explicitly
# (RoutesToDNS = true) if some future host genuinely needs split-uplink DNS.
{
  options.systemd.network.networks = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      config.dhcpV4Config.RoutesToDNS = lib.mkDefault false;
    });
  };
}
