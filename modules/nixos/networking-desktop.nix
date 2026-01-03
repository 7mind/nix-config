{ lib, config, pkgs, ... }: {
  options = {
    smind.net.desktop.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.net.enable && config.smind.isDesktop;
      description = "Enable NetworkManager with iwd for desktop systems";
    };

    smind.net.opensnitch.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable OpenSnitch application firewall";
    };
  };

  config = lib.mkMerge [
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
            "except:interface-name:enp*"
          ];
        };

        wireless.iwd.enable = true;
        wireless.enable = false;
      };

      systemd.services.NetworkManager-wait-online.enable = false;
    })

    (lib.mkIf config.smind.net.opensnitch.enable {
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
