{ lib, config, cfg-meta, pkgs, ... }:
let
  resolvedWithCache = {
    enable = true;
    settings = {
      Resolve = {
        Cache = "no-negative";
        DNSStubListener = "yes";
        DNSStubListenerExtra = [ "[::1]:53" ];
        LLMNR = "false";
      };
    };
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
      default = config.smind.net.mode == "systemd-networkd" && config.smind.isDesktop;
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
          allowedUDPPorts = [ 546 547 ] # enables dhcpv6
            ++ (if config.smind.net.upnp.enable then
            [
              1900 # UPnP service discovery
              5351 # ipv6 pcp port
            ]
          else [ ]);

          # support SSDP https://serverfault.com/a/911286/9166
          # https://discourse.nixos.org/t/ssdp-firewall-support/17809
          # https://discourse.nixos.org/t/how-to-add-conntrack-helper-to-firewall/798
          # https://discourse.nixos.org/t/firewall-rules-with-rygel-gnome-sharing/17471
          extraPackages = lib.mkIf config.smind.net.upnp.enable [ pkgs.ipset ];

          extraCommands = lib.mkIf config.smind.net.upnp.enable ''
            set -xe
            function apply_if_not_yet() {
              cmd=$1
              shift
              shift
              $cmd -C $* >/dev/null 2>&1 || \
                $cmd -A $*
            }

            ipset list upnp >/dev/null 2>&1 || ipset create upnp hash:ip,port timeout 3
            apply_if_not_yet iptables -A OUTPUT -p udp -m udp --dport 1900 -j SET --add-set upnp src,src --exist
            apply_if_not_yet iptables -A INPUT -p udp -m set --match-set upnp dst,dst -j ACCEPT

            ipset list upnp6 >/dev/null 2>&1 || ipset create upnp6 hash:ip,port family inet6 timeout 3
            apply_if_not_yet ip6tables -A OUTPUT -p udp -m udp --dport 1900 -j SET --add-set upnp6 src,src --exist
            apply_if_not_yet ip6tables -A INPUT -p udp -m set --match-set upnp6 dst,dst -j ACCEPT
          '';

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
              }
            )
          ) cfg.vlans;

          vlanBridgeNetworks = lib.mapAttrs' (name: vlan:
            lib.nameValuePair "31-${vlan.bridge.name}" {
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
            }
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
