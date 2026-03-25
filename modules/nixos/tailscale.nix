{ config, lib, pkgs, ... }:

let
  ipRuleCmd = "${pkgs.iproute2}/bin/ip";
  lanCidr = "192.168.0.0/16";
  rulePref = "5000";
in
{
  options = {
    smind.net.tailscale.enable = lib.mkEnableOption "tailscale service";
    smind.net.tailscale.gro-interface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The interface to apply the UDP GRO fix to.";
    };
    smind.net.tailscale.home-gateway-prefix = lib.mkOption {
      type = lib.types.str;
      default = "192.168.10.";
      description = "Gateway IP prefix used to detect the home network. When the default route gateway matches this prefix, LAN routes are preferred over Tailscale subnet routes.";
    };
  };

  config = lib.mkIf config.smind.net.tailscale.enable {
    # Recommended `tailscale up` flags:
    #   clients (desktops/laptops): --accept-dns --accept-routes --ssh
    #   servers:                    --ssh --exit-node-allow-lan-access
    services.tailscale = {
      enable = true;
      interfaceName = "tailscale0";
      useRoutingFeatures = if (config.smind.isDesktop || config.smind.isLaptop) then "client" else "server";
    };

    systemd.services.tailscale-operator = lib.mkIf (config.smind.host.owner != null) {
      description = "Set tailscale operator to ${config.smind.host.owner}";
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.tailscale}/bin/tailscale set --operator=${config.smind.host.owner}";
        RemainAfterExit = true;
      };
    };

    systemd.network.wait-online.ignoredInterfaces = [ "tailscale0" ];

    # On non-laptops, always prefer LAN routes over Tailscale subnet routes.
    systemd.services.ip-rules = lib.mkIf (!config.smind.isLaptop) {
      description = "Always prefer LAN routes over tailscale";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStartPre = "-${ipRuleCmd} rule del to ${lanCidr} pref ${rulePref} lookup main";
        ExecStart = "${ipRuleCmd} rule add to ${lanCidr} pref ${rulePref} lookup main";
        ExecStop = "-${ipRuleCmd} rule del to ${lanCidr} pref ${rulePref} lookup main";
        RemainAfterExit = true;
      };
    };

    # On laptops, dynamically toggle the LAN-over-Tailscale ip rule based on
    # whether we're on the home network. When away, Tailscale subnet routing is
    # needed to reach home LAN; when at home, the local gateway should be preferred
    # so that traffic to other local subnets (e.g. 192.168.13.0/24) doesn't get
    # routed through a Tailscale peer advertising 192.168.0.0/16.
    networking.networkmanager.dispatcherScripts = lib.mkIf (config.smind.isLaptop && config.smind.net.mode == "networkmanager") [
      {
        type = "basic";
        source = pkgs.writeScript "tailscale-lan-rule" ''
          #!${pkgs.bash}/bin/bash
          IFACE="$1"
          ACTION="$2"
          GATEWAY_PREFIX="${config.smind.net.tailscale.home-gateway-prefix}"

          add_rule() {
            ${ipRuleCmd} rule del to ${lanCidr} pref ${rulePref} lookup main 2>/dev/null
            ${ipRuleCmd} rule add to ${lanCidr} pref ${rulePref} lookup main
          }

          del_rule() {
            ${ipRuleCmd} rule del to ${lanCidr} pref ${rulePref} lookup main 2>/dev/null
          }

          case "$ACTION" in
            up|dhcp4-change)
              GATEWAY=$(${ipRuleCmd} route show default dev "$IFACE" 2>/dev/null | ${pkgs.gawk}/bin/awk '/default/ {print $3; exit}')
              if [[ "$GATEWAY" == "$GATEWAY_PREFIX"* ]]; then
                add_rule
              else
                del_rule
              fi
              ;;
            down)
              del_rule
              ;;
          esac
        '';
      }
    ];

    systemd.services.tailscale-gro-fix = lib.mkIf (config.smind.net.tailscale.gro-interface != null) {
      description = "Apply Tailscale UDP GRO fix";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.ethtool}/bin/ethtool -K ${config.smind.net.tailscale.gro-interface} rx-udp-gro-forwarding on rx-gro-list off";
        RemainAfterExit = true;
      };
    };
  };
}
