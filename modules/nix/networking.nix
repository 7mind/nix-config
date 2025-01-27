{ pkgs, lib, config, cfg-meta, ... }: {
  options = {
    smind.net.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
    smind.net.desktop.enable = lib.mkOption {
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


  };

  config = lib.mkMerge [
    {
      assertions =
        [
          ({
            assertion = config.smind.net.main-interface != "";
            message = "set config.smind.net.main-interface";
          })
        ];
    }

    (lib.mkIf config.smind.net.enable {
      systemd.network.enable = true;

      networking = {
        hostName = lib.mkDefault cfg-meta.hostname;

        enableIPv6 = true;
        useNetworkd = true;
        useDHCP = false;
        dhcpcd.enable = false;
        firewall = {
          enable = true;
          # # should allow slaac
          # allowedICMPTypes = [
          #   "echo-request"
          #   "echo-reply"
          #   "destination-unreachable"
          #   "packet-too-big"
          #   "time-exceeded"
          #   "parameter-problem"
          #   "router-solicitation"
          #   "router-advertisement"
          #   "neighbour-solicitation"
          #   "neighbour-advertisement"
          #   "redirect"
          # ];
          allowedUDPPorts = [ 546 547 ]; # enables dhcpv6
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
              MACAddress = "d0:94:66:55:aa:11";
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
    })

    (lib.mkIf config.smind.net.desktop.enable {
      networking = {
        networkmanager = {
          enable = true;
          wifi.backend = "iwd";
          unmanaged = [
            "type:ethernet"
            "type:tun"
            "type:vlan"
            "type:bridge"
            "type:loopback"
            "except:type:wifi"
            "except:type:wifi-p2p"
            "except:interface-name:wlan*"
          ];
        };

        wireless.iwd.enable = true;
        wireless.enable = false;
      };

      systemd.services.NetworkManager-wait-online.enable = false;

      # services.opensnitch = {
      #   enable = true;
      #   settings = {
      #     DefaultAction = "allow";
      #     Firewall = "nftables";
      #     ProcMonitorMethod = "ebpf";
      #   };
      # };

      # environment.systemPackages = with pkgs; [
      #   opensnitch-ui
      # ];
    })
  ];
}
