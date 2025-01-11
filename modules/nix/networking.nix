{ pkgs, lib, config, ... }: {
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
        enableIPv6 = true;
        useNetworkd = true;
        useDHCP = false;
        dhcpcd.enable = false;

        firewall = {
          enable = true;
        };

        bridges."${config.smind.net.main-bridge}".interfaces = [ config.smind.net.main-interface ];
      };

      services.resolved = {
        enable = true;
        extraConfig = "Cache=no-negative";
        llmnr = "false";
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

      services.opensnitch = {
        enable = true;
        settings = {
          DefaultAction = "allow";
          Firewall = "nftables";
          ProcMonitorMethod = "ebpf";
        };
      };

      environment.systemPackages = with pkgs; [
        opensnitch-ui
      ];
    })
  ];
}
