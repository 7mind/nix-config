{ lib, config, cfg-meta, pkgs, ... }: {
  options = {
    smind.net.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };

    smind.net.upnp.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.net.enable && config.smind.isDesktop;
      description = "";
    };

    smind.net.main-interface = lib.mkOption {
      type = lib.types.str;
      description = "";
    };

    smind.net.main-bridge = lib.mkOption {
      type = lib.types.str;
      default = "br-main";
      description = "";
    };

    smind.net.main-macaddr = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "";
    };
  };

  config =
    (lib.mkIf config.smind.net.enable {
      assertions =
        [
          ({
            assertion =
              (
                config.smind.net.main-interface != "" &&
                config.smind.net.main-macaddr != ""
              )
            ;
            message = "set config.smind.net.main-interface";
          })
        ];

      systemd.network.enable = true;

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
            ipset create upnp hash:ip,port timeout 3 || true
            iptables -A OUTPUT -p udp -m udp --dport 1900 -j SET --add-set upnp src,src --exist
            iptables -A INPUT -p udp -m set --match-set upnp dst,dst -j ACCEPT
          '';

        };

        bridges."${config.smind.net.main-bridge}".interfaces = [ config.smind.net.main-interface ];
      };

      services.resolved = {
        enable = true;
        extraConfig = "Cache=no-negative";
        llmnr = "false";
      };

      services.avahi = {
        enable = true;
        nssmdns4 = true;
        nssmdns6 = false;
        openFirewall = true;
      };

      # boot.kernel.sysctl = {
      #   "net.ipv6.conf.br-main.accept_ra" = 1;
      # };

      systemd.network = {
        networks = {
          "20-${config.smind.net.main-bridge}" = {
            name = "${config.smind.net.main-bridge}";
            DHCP = "yes";

            linkConfig = {
              MACAddress = "${config.smind.net.main-macaddr}";
              RequiredForOnline = "routable";
            };

            networkConfig = {
              IPv6PrivacyExtensions = "no";
              DHCPPrefixDelegation = "yes";
              IPv6AcceptRA = "yes";
              LinkLocalAddressing = "yes";
            };

            dhcpV4Config = {
              SendHostname = true;
              Hostname = "${config.networking.hostName}.${config.networking.domain}";
              UseDomains = true;
            };

            dhcpV6Config = {
              SendHostname = true;
              Hostname = "${config.networking.hostName}-ipv6.${config.networking.domain}";
              UseDomains = true;
            };

            # routes = [{
            #   Gateway = "192.168.10.1";
            #   Destination = "0.0.0.0/0";
            #   Metric = 500;
            # }];
          };
        };
      };

      systemd.network.wait-online = {
        enable = false;
        extraArgs =
          [ "--interface=br-infra" ];
      };
    });
}
