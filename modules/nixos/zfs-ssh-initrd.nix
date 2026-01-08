{ pkgs, lib, config, ... }:
{
  options = {
    smind.zfs.initrd-unlock.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow ZFS to be unlocked through SSH running in initrd";
    };

    smind.zfs.initrd-unlock.interface = lib.mkOption {
      type = lib.types.str;
      default = config.smind.net.main-bridge;
      description = "network interface to configure";
    };

    smind.zfs.initrd-unlock.macaddr = lib.mkOption {
      type = lib.types.str;
      description = "network interface to configure / mac";
    };

    smind.zfs.initrd-unlock.bridge-slave = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if config.smind.net.enable then config.smind.net.main-interface else null;
      description = "Physical interface to enslave to the bridge (auto-detected from smind.net.main-interface when smind.net.enable is true)";
    };

    smind.zfs.initrd-unlock.hostname = lib.mkOption {
      type = lib.types.str;
      # default = "initrd-${config.networking.hostName}.${config.networking.domain}";
      default = "initrd-${config.networking.hostName}";
      description = "hostname to use (must differ from primary system hostname)";
    };
  };

  config = lib.mkIf config.smind.zfs.initrd-unlock.enable {
    assertions = [
      ({
        assertion = config.smind.zfs.initrd-unlock.interface != "";
        message = "set config.smind.zfs.initrd-unlock.interface";
      })
      ({
        assertion = config.smind.zfs.initrd-unlock.hostname != "" && config.networking.hostName != "" && config.smind.zfs.initrd-unlock.hostname != config.networking.hostName;
        message = "set config.smind.zfs.initrd-unlock.hostname";
      })
    ];

    boot.initrd = {
      # Load bridge module when using a bridge interface
      kernelModules = lib.mkIf (config.smind.zfs.initrd-unlock.bridge-slave != null) [ "bridge" ];

      systemd =
        {
          enable = true;
          emergencyAccess = true;

          initrdBin = with pkgs; [
            busybox
          ];

          #extraBin = {
          ##  zfs-unlock-shell = pkgs.writeScript "zfs-unlock-shell" ''
          #    #!/bin/sh
          #    exec /bin/systemd-tty-ask-password-agent --watch
          #  '';
          #};
          #users.root.shell = "/bin/zfs-unlock-shell";

          services.zfs-remote-unlock = {
            description = "Prepare for ZFS remote unlock";
            wantedBy = [ "initrd.target" ];
            after = [
              # "systemd-networkd.service"
              "network-online.target"
            ];
            wants = [ "network-online.target" ];

            path = with pkgs; [
              zfs
            ];

            serviceConfig.Type = "oneshot";
            script = ''
              echo "systemctl default" >> /var/empty/.profile
            '';
          };

          network = {
            enable = true;
            wait-online.enable = true;
            wait-online.timeout = 10;
            wait-online.extraArgs = [ config.smind.zfs.initrd-unlock.interface ];

            # systemd.network.netdevs from main system are NOT copied to initrd
            # We must explicitly create bridge and slave config here
            netdevs = lib.mkIf (config.smind.zfs.initrd-unlock.bridge-slave != null) {
              "10-${config.smind.zfs.initrd-unlock.interface}" = {
                netdevConfig = {
                  Kind = "bridge";
                  Name = config.smind.zfs.initrd-unlock.interface;
                  MACAddress = config.smind.zfs.initrd-unlock.macaddr;
                };
              };
            };

            networks = {
              # Bridge slave config (when using a bridge)
              "10-${config.smind.zfs.initrd-unlock.interface}-slave" = lib.mkIf (config.smind.zfs.initrd-unlock.bridge-slave != null) {
                name = config.smind.zfs.initrd-unlock.bridge-slave;
                bridge = [ config.smind.zfs.initrd-unlock.interface ];
              };

              # DHCP config for bridge/interface
              "20-${config.smind.zfs.initrd-unlock.interface}" = {
                enable = true;
                name = config.smind.zfs.initrd-unlock.interface;
                DHCP = "ipv4";

                linkConfig = {
                  RequiredForOnline = "routable";
                  # Only set MAC directly on interface if not using a bridge (bridge has MAC in netdev)
                  MACAddress = lib.mkIf (config.smind.zfs.initrd-unlock.bridge-slave == null) config.smind.zfs.initrd-unlock.macaddr;
                };

                dhcpV4Config = {
                  SendHostname = true;
                  Hostname = config.smind.zfs.initrd-unlock.hostname;
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
