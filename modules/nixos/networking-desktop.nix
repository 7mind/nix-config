{ lib, config, ... }: {
  options = {
    smind.net.desktop.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.net.enable && config.smind.isDesktop;
      description = "";
    };
  };

  config =
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
    });
}
