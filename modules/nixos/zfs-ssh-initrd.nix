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
      default = config.smind.net.main-interface;
      description = "network interface to configure";
    };

    smind.zfs.initrd-unlock.hostname = lib.mkOption {
      type = lib.types.str;
      default = "initrd-${config.networking.hostName}.${config.networking.domain}";
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

          services.zfs-remote-unlock = {
            description = "Prepare for ZFS remote unlock";
            wantedBy = [ "initrd.target" ];
            after = [ "systemd-networkd.service" ];

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

            networks.bootnet = {
              enable = true;
              name = config.smind.zfs.initrd-unlock.interface;
              DHCP = "yes";
              dhcpV4Config = {
                SendHostname = true;
                Hostname = config.smind.zfs.initrd-unlock.hostname;
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
