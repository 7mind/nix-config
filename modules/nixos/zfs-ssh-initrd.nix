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
      default = null;
      description = "Physical interface to enslave to the bridge (required when interface is a bridge)";
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
      systemd =
        {
          enable = true;
          emergencyAccess = true;

          initrdBin = with pkgs; [
            busybox
          ];

          extraBin = {
            zfs-unlock-shell = pkgs.writeScript "zfs-unlock-shell" ''
              #!/bin/sh
              exec /bin/systemd-tty-ask-password-agent --watch
            '';
          };

          users.root.shell = "/bin/zfs-unlock-shell";

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

            # Main system network config is partially copied to initrd but bridge configs are missing:
            # - Bridge netdevs are NOT copied
            # - Bridge slave network configs lose bridge= directive
            # See: https://github.com/NixOS/nixpkgs/blob/nixos-unstable/nixos/modules/system/boot/networkd.nix
            # We explicitly create bridge and slave config when bridge-slave is set

            netdevs = lib.mkIf (config.smind.zfs.initrd-unlock.bridge-slave != null) {
              "10-${config.smind.zfs.initrd-unlock.interface}" = {
                netdevConfig = {
                  Kind = "bridge";
                  Name = config.smind.zfs.initrd-unlock.interface;
                  MACAddress = config.smind.zfs.initrd-unlock.macaddr;
                };
              };
            };

            networks = lib.mkMerge [
              # Bridge slave config (physical interface -> bridge)
              (lib.mkIf (config.smind.zfs.initrd-unlock.bridge-slave != null) {
                "20-${config.smind.zfs.initrd-unlock.bridge-slave}-initrd" = {
                  name = config.smind.zfs.initrd-unlock.bridge-slave;
                  bridge = [ config.smind.zfs.initrd-unlock.interface ];
                  networkConfig = {
                    # Clear any VLAN config from inherited files
                    VLAN = [ ];
                  };
                };
              })

              # Bridge/interface network config with DHCP
              {
                "99-${config.smind.zfs.initrd-unlock.interface}" = {
                  enable = true;
                  name = config.smind.zfs.initrd-unlock.interface;
                  DHCP = "ipv4";

                  linkConfig = {
                    RequiredForOnline = "routable";
                  } // lib.optionalAttrs (config.smind.zfs.initrd-unlock.bridge-slave == null) {
                    # Only set MAC on interface directly if not using a bridge
                    MACAddress = config.smind.zfs.initrd-unlock.macaddr;
                  };

                  dhcpV4Config = {
                    SendHostname = true;
                    Hostname = config.smind.zfs.initrd-unlock.hostname;
                  };
                };
              }
            ];

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
