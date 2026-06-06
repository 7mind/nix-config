{ lib, config, pkgs, ... }: {
  options = {
    smind.net.desktop.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.net.mode == "systemd-networkd" && config.smind.isDesktop;
      description = "Enable NetworkManager with iwd for desktop systems";
    };

  };

  config = lib.mkIf config.smind.net.desktop.enable {
      networking = {
        networkmanager = {
          enable = true;
          wifi.backend = "wpa_supplicant";

          # On desktops, only manage wifi; on laptops, manage everything
          unmanaged = lib.mkIf (!config.smind.isLaptop) [
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

          settings.connectivity = {
            uri = "http://nmcheck.gnome.org/check_network_status.txt";
            response = "NetworkManager is online";
            interval = 300;
          };
        };

        wireless.iwd.enable = false;
        wireless.enable = true;
      };

      # On desktops NM does not manage ethernet, so its GIO monitor reports no
      # connectivity; use the base monitor. On laptops NM manages everything, so
      # the networkmanager monitor works and is needed for captive-portal detection.
      environment.sessionVariables.GIO_USE_NETWORK_MONITOR =
        if config.smind.isLaptop then "networkmanager" else "base";

      environment.systemPackages = with pkgs; [
        iw
        wirelesstools
      ];

      systemd.services.NetworkManager-wait-online.enable = false;
    };
}
