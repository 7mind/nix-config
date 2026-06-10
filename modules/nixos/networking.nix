{ lib, config, cfg-meta, pkgs, ... }:
let
  # Applied wherever systemd-resolved runs, regardless of net.mode. Negative
  # caching off so disappearing-then-reappearing DHCP hostnames (containers,
  # dynamic peers) resolve on the next query, not after the SOA MINIMUM TTL.
  resolvedGlobalSettings = {
    Resolve = {
      Cache = "no-negative";
      DNSStubListener = "yes";
      DNSStubListenerExtra = [ "[::1]:53" ];
      LLMNR = "false";
    };
  };

  resolvedWithCache = {
    enable = true;
    settings = resolvedGlobalSettings;
  };
in
{
  options = {
    smind.net.mode = lib.mkOption {
      type = lib.types.enum [ "systemd-networkd" "networkmanager" "none" ];
      default = "none";
      description = "Networking mode";
    };

    smind.net.upnp.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.isDesktop;
      description = "Enable miniupnpd for UPnP port forwarding";
    };

    smind.net.main-interface = lib.mkOption {
      type = lib.types.str;
      description = "Primary network interface name";
    };

    smind.net.main-bridge = lib.mkOption {
      type = lib.types.str;
      default = "br-main";
      description = "Main bridge interface name";
    };

    smind.net.main-bridge-macaddr = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "";
    };

    smind.net.main-macaddr = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "";
    };

    smind.net.ipv6Token = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Stable IPv6 interface identifier (the low 64 bits) for the main
        bridge/interface, set as the systemd-networkd [IPv6AcceptRA] Token=.
        When non-empty, the SLAAC address derived from the router-advertised
        prefix uses this fixed suffix instead of one derived from the MAC or a
        random value, so the host keeps a predictable IPv6 address across boots
        and hardware changes. Written in IPv6 suffix notation, e.g. "::0250".
      '';
      example = "::0250";
    };

    smind.net.bridge.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to create a bridge on top of the primary interface.
        When true (default), a bridge is created and DHCP runs on it.
        When false, DHCP runs directly on the primary interface.
        Hosts with a single NIC and no need for L2 bridging (VMs,
        containers) should set this to false.
      '';
    };

    smind.net.vlans = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          id = lib.mkOption {
            type = lib.types.int;
            description = "VLAN ID (802.1Q tag)";
          };
          macAddress = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "MAC address for the VLAN interface. When empty, inherits from the parent interface.";
          };
          ipv6Token = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = ''
              Stable IPv6 interface identifier (the low 64 bits) for this
              VLAN's L3 interface (the bridge when bridge.enable = true, else
              the VLAN sub-interface), set as the [IPv6AcceptRA] Token=. When
              non-empty, the SLAAC address keeps this fixed suffix across boots.
              Written in IPv6 suffix notation, e.g. "::0250".
            '';
            example = "::0250";
          };
          dhcp = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to use DHCP on this VLAN interface (or on its bridge if bridge.enable = true)";
          };
          bridge.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              When true, wrap the VLAN sub-interface in a Linux bridge so that
              nixos-containers (or other L2 consumers) can attach to the VLAN.
              The VLAN interface becomes a bridge slave (no L3); DHCP, if
              enabled, runs on the bridge.
            '';
          };
          bridge.name = lib.mkOption {
            type = lib.types.str;
            default = "br-${name}";
            defaultText = lib.literalExpression ''"br-''${vlanKey}"'';
            description = "Bridge interface name when bridge.enable = true.";
          };
        };
      }));
      default = { };
      description = ''
        Additional VLANs to create on the primary network interface.
        Each key is used as the VLAN interface name suffix
        (e.g. key "iot-wifi" → interface "vlan-iot-wifi").
      '';
      example = lib.literalExpression ''
        {
          iot-wifi  = { id = 13; };
          iot-wired = { id = 14; bridge.enable = true; };
        }
      '';
    };

  };

  config = lib.mkMerge [
    {
      # Applies even when net.mode is "none" and the host hand-rolls networking.
      services.resolved.settings = resolvedGlobalSettings;
    }

    # SSDP/UPnP firewall support (all net.modes). Inbound SSDP M-SEARCH
    # responses are unicast from the IGD with no conntrack association to the
    # client's multicast M-SEARCH, so nixos-fw drops them. The ipset trick
    # records (saddr,sport) of outbound SSDP multicast and accepts inbound
    # packets matching (daddr,dport) within 3s. The accept must target the
    # `nixos-fw` chain, not raw INPUT, or nixos-fw rejects first.
    # Refs:
    #   https://serverfault.com/a/911286/9166
    #   https://github.com/NixOS/nixpkgs/issues/161328
    (lib.mkIf config.smind.net.upnp.enable {
      networking.firewall = {
        allowedUDPPorts = [
          1900 # SSDP — needed inbound for unsolicited multicast NOTIFYs
          5351 # NAT-PMP / PCP
        ];
        extraPackages = [ pkgs.ipset ];
        extraCommands = ''
          set -xe
          function apply_if_not_yet() {
            cmd=$1
            shift
            shift
            $cmd -C "$@" >/dev/null 2>&1 || \
              $cmd -A "$@"
          }

          ipset list upnp >/dev/null 2>&1 || ipset create upnp hash:ip,port timeout 3
          apply_if_not_yet iptables -A OUTPUT -d 239.255.255.250/32 -p udp -m udp --dport 1900 -j SET --add-set upnp src,src --exist
          apply_if_not_yet iptables -A nixos-fw -p udp -m set --match-set upnp dst,dst -j nixos-fw-accept

        '' + lib.optionalString config.networking.enableIPv6 ''
          ipset list upnp6 >/dev/null 2>&1 || ipset create upnp6 hash:ip,port family inet6 timeout 3
          apply_if_not_yet ip6tables -A OUTPUT -d ff02::c/128 -p udp -m udp --dport 1900 -j SET --add-set upnp6 src,src --exist
          apply_if_not_yet ip6tables -A nixos-fw -p udp -m set --match-set upnp6 dst,dst -j nixos-fw-accept
        '';
      };
    })
    (lib.mkIf (config.smind.net.mode == "systemd-networkd") {
      assertions =
        [
          ({
            assertion = config.smind.net.main-interface != "";
            message = "smind.net.main-interface must be set for systemd-networkd mode";
          })
          ({
            assertion = config.smind.net.bridge.enable -> config.smind.net.main-bridge-macaddr != "";
            message = "smind.net.main-bridge-macaddr must be set when bridge is enabled";
          })
        ];

      services.networkd-dispatcher.enable = true;

      networking = {
        hostName = lib.mkDefault cfg-meta.hostname;

        enableIPv6 = true;
        useNetworkd = true;
        useDHCP = false;
        dhcpcd.enable = false;
        firewall = {
          enable = true;
          allowedUDPPorts = [ 546 547 ]; # enables dhcpv6
        };

        # Bridge is created via systemd.network.netdevs for proper MAC control
        # networking.bridges doesn't support MAC address setting
      };

      services.resolved = resolvedWithCache;

      services.avahi = {
        enable = true;
        nssmdns4 = true;
        nssmdns6 = false;
        openFirewall = true;
      };

      # boot.kernel.sysctl = {
      #   "net.ipv6.conf.br-main.accept_ra" = 1;
      # };


      systemd.network =
        let
          cfg = config.smind.net;
          iface = cfg.main-interface;
          bridged = cfg.bridge.enable;
          hostname =
            if config.networking.domain != null
            then "${config.networking.hostName}.${config.networking.domain}"
            else config.networking.hostName;
          hostname-v6 =
            if config.networking.domain != null
            then "${config.networking.hostName}-ipv6.${config.networking.domain}"
            else "${config.networking.hostName}-ipv6";

          vlanNetdevs = lib.mapAttrs' (name: vlan:
            lib.nameValuePair "30-vlan-${name}" {
              netdevConfig = {
                Kind = "vlan";
                Name = "vlan-${name}";
              } // lib.optionalAttrs (vlan.macAddress != "") {
                MACAddress = vlan.macAddress;
              };
              vlanConfig.Id = vlan.id;
            }
          ) cfg.vlans;

          vlanBridgeNetdevs = lib.mapAttrs' (name: vlan:
            lib.nameValuePair "31-${vlan.bridge.name}" {
              netdevConfig = {
                Kind = "bridge";
                Name = vlan.bridge.name;
              } // lib.optionalAttrs (vlan.macAddress != "") {
                MACAddress = vlan.macAddress;
              };
            }
          ) (lib.filterAttrs (_: v: v.bridge.enable) cfg.vlans);

          vlanNetworks = lib.mapAttrs' (name: vlan:
            lib.nameValuePair "30-vlan-${name}" (
              if vlan.bridge.enable then {
                # Bridged VLAN: sub-iface is a port on br-<name>; no L3 here.
                name = "vlan-${name}";
                bridge = [ vlan.bridge.name ];
                linkConfig.RequiredForOnline = "enslaved";
              } else {
                name = "vlan-${name}";
                DHCP = if vlan.dhcp then "yes" else "no";
                linkConfig.RequiredForOnline = "no";
                networkConfig = {
                  IPv6AcceptRA = "yes";
                  LinkLocalAddressing = "yes";
                };
                dhcpV4Config = lib.mkIf vlan.dhcp {
                  SendHostname = true;
                  Hostname = hostname;
                  UseRoutes = false;
                };
              } // lib.optionalAttrs (vlan.ipv6Token != "") {
                ipv6AcceptRAConfig.Token = vlan.ipv6Token;
              }
            )
          ) cfg.vlans;

          vlanBridgeNetworks = lib.mapAttrs' (name: vlan:
            lib.nameValuePair "31-${vlan.bridge.name}" ({
              name = vlan.bridge.name;
              DHCP = if vlan.dhcp then "yes" else "no";
              linkConfig.RequiredForOnline = "no";
              networkConfig = {
                IPv6AcceptRA = "yes";
                LinkLocalAddressing = "yes";
              };
              dhcpV4Config = lib.mkIf vlan.dhcp {
                SendHostname = true;
                Hostname = hostname;
                UseRoutes = false;
              };
            } // lib.optionalAttrs (vlan.ipv6Token != "") {
              ipv6AcceptRAConfig.Token = vlan.ipv6Token;
            })
          ) (lib.filterAttrs (_: v: v.bridge.enable) cfg.vlans);

          vlanNames = lib.mapAttrsToList (name: _: "vlan-${name}") cfg.vlans;

          dhcpNetworkConfig = {
            DHCP = "yes";
            linkConfig.RequiredForOnline = "routable";
            networkConfig = {
              IPv6PrivacyExtensions = "no";
              DHCPPrefixDelegation = "yes";
              IPv6AcceptRA = "yes";
              LinkLocalAddressing = "yes";
            };
            dhcpV4Config = {
              SendHostname = true;
              Hostname = hostname;
              UseDomains = true;
            };
            dhcpV6Config = {
              SendHostname = true;
              Hostname = hostname-v6;
              UseDomains = true;
            };
          } // lib.optionalAttrs (cfg.ipv6Token != "") {
            ipv6AcceptRAConfig.Token = cfg.ipv6Token;
          };
        in
        {
          enable = true;

          links = lib.mkIf (cfg.main-macaddr != "") {
            "10-${iface}.link" = {
              matchConfig.PermanentMACAddress = cfg.main-macaddr;
              linkConfig.Name = iface;
            };
          };

          netdevs = (lib.optionalAttrs bridged {
            "10-${cfg.main-bridge}" = {
              netdevConfig = {
                Kind = "bridge";
                Name = cfg.main-bridge;
                MACAddress = cfg.main-bridge-macaddr;
              };
            };
          }) // vlanNetdevs // vlanBridgeNetdevs;

          networks = (if bridged then {
            # Bridged: main-interface is a bridge slave.
            "10-${iface}" = {
              name = iface;
              bridge = [ cfg.main-bridge ];
              vlan = vlanNames;
              linkConfig.RequiredForOnline = "enslaved";
            };
            "20-${cfg.main-bridge}" = { name = cfg.main-bridge; } // dhcpNetworkConfig;
          } else {
            # Bridgeless: DHCP directly on main-interface.
            "10-${iface}" = { name = iface; vlan = vlanNames; } // dhcpNetworkConfig;
          }) // vlanNetworks // vlanBridgeNetworks;

          wait-online = {
            enable = false;
            extraArgs =
              [ "--interface=br-infra" ];
          };
        };
    })

    (lib.mkIf (config.smind.net.mode == "networkmanager") {
      networking.networkmanager.enable = true;
      services.resolved = resolvedWithCache;
    })
  ];
}
