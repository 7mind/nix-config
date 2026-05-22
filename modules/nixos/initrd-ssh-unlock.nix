{ pkgs, lib, config, ... }:
{
  options = {
    smind.initrd-unlock.enable = lib.mkEnableOption "encrypted root (LUKS or ZFS) to be unlocked through SSH running in initrd";

    smind.initrd-unlock.interface = lib.mkOption {
      type = lib.types.str;
      default = config.smind.net.main-bridge;
      description = "network interface to configure";
    };

    smind.initrd-unlock.macaddr = lib.mkOption {
      type = lib.types.str;
      description = "network interface to configure / mac";
    };

    smind.initrd-unlock.bridge-slave = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if config.smind.net.mode == "systemd-networkd" then config.smind.net.main-interface else null;
      description = "Physical interface to enslave to the bridge (auto-detected from smind.net.main-interface when smind.net.mode is systemd-networkd)";
    };

    smind.initrd-unlock.hostname = lib.mkOption {
      type = lib.types.str;
      default = "initrd-${config.networking.hostName}";
      description = "hostname to use (must differ from primary system hostname)";
    };
  };

  config = lib.mkIf config.smind.initrd-unlock.enable {
    assertions = [
      ({
        assertion = config.smind.initrd-unlock.interface != "";
        message = "set config.smind.initrd-unlock.interface";
      })
      ({
        assertion = config.smind.initrd-unlock.hostname != "" && config.networking.hostName != "" && config.smind.initrd-unlock.hostname != config.networking.hostName;
        message = "set config.smind.initrd-unlock.hostname";
      })
      ({
        assertion = builtins.match ".*\\..*" config.smind.initrd-unlock.hostname == null;
        message = "smind.initrd-unlock.hostname must be a single DNS label; systemd-networkd DHCP client does not send dotted hostnames";
      })
    ];

    boot.initrd = {
      # Load bridge module when using a bridge interface
      kernelModules = lib.mkIf (config.smind.initrd-unlock.bridge-slave != null) [ "bridge" ];

      systemd =
        {
          enable = true;
          emergencyAccess = true;

          initrdBin = with pkgs; [
            busybox
          ];

          # Replace root's login shell so any SSH session immediately watches
          # systemd's password-agent socket. Works for both LUKS (cryptsetup)
          # and ZFS (zfs-import-*.service uses systemd-ask-password too).
          extraBin = {
            unlock-shell = pkgs.writeScript "unlock-shell" ''
              #!/bin/sh
              exec /bin/systemd-tty-ask-password-agent --watch
            '';
          };
          users.root.shell = "/bin/unlock-shell";

          network = {
            enable = true;
            wait-online.enable = true;
            wait-online.timeout = 10;
            wait-online.extraArgs = [ config.smind.initrd-unlock.interface ];

            # systemd.network.{links,netdevs} from the main system are NOT copied
            # to initrd, so we must recreate the MAC-based rename and bridge setup.
            links = lib.mkIf (config.smind.initrd-unlock.bridge-slave != null && config.smind.net.main-macaddr != "") {
              "10-${config.smind.initrd-unlock.bridge-slave}.link" = {
                matchConfig.PermanentMACAddress = config.smind.net.main-macaddr;
                linkConfig.Name = config.smind.initrd-unlock.bridge-slave;
              };
            };

            netdevs = lib.mkIf (config.smind.initrd-unlock.bridge-slave != null) {
              "10-${config.smind.initrd-unlock.interface}" = {
                netdevConfig = {
                  Kind = "bridge";
                  Name = config.smind.initrd-unlock.interface;
                  MACAddress = config.smind.initrd-unlock.macaddr;
                };
              };
            };

            networks = {
              # Bridge slave config (when using a bridge)
              "10-${config.smind.initrd-unlock.interface}-slave" = lib.mkIf (config.smind.initrd-unlock.bridge-slave != null) {
                name = config.smind.initrd-unlock.bridge-slave;
                bridge = [ config.smind.initrd-unlock.interface ];
              };

              # DHCP config for bridge/interface
              "20-${config.smind.initrd-unlock.interface}" = {
                enable = true;
                name = config.smind.initrd-unlock.interface;
                DHCP = "ipv4";

                linkConfig = {
                  RequiredForOnline = "routable";
                  # Only set MAC directly on interface if not using a bridge (bridge has MAC in netdev)
                  MACAddress = lib.mkIf (config.smind.initrd-unlock.bridge-slave == null) config.smind.initrd-unlock.macaddr;
                };

                dhcpV4Config = {
                  SendHostname = true;
                  Hostname = config.smind.initrd-unlock.hostname;
                };
              };
            };

          };
        };


      network = {
        enable = true;

        ssh = {
          enable = true;
          port = 22;

          # `ssh-keygen -t ed25519 -N "" -f /path/to/ssh_host_ed25519_key`
          # hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];

          # authorizedKeys = config.sshkeys.pavel-all
          #   ++ [ config.sshkeys.initrd ];
        };
      };
    };
  };

}
