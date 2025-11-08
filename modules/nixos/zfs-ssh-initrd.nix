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

            # in fact, main config is being copied there: https://github.com/NixOS/nixpkgs/blob/nixos-unstable/nixos/modules/system/boot/networkd.nix#L3306
            # though it's mangled
            networks."20-${config.smind.zfs.initrd-unlock.interface}" = {
              enable = true;
              name = config.smind.zfs.initrd-unlock.interface;
              DHCP = "ipv4";
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
