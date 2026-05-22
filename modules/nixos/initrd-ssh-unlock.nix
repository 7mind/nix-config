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
      default =
        if config.smind.net.mode == "systemd-networkd" && config.smind.net.bridge.enable
        then config.smind.net.main-interface
        else null;
      description = ''
        Physical interface to enslave to the bridge in initrd. Auto-detected
        from smind.net.main-interface when smind.net.mode is systemd-networkd
        AND smind.net.bridge.enable is true. Otherwise null, meaning DHCP
        runs directly on `interface` with no bridge synthesis — required
        when there is no bridge (e.g. single-NIC hosts) since a bridge named
        the same as the only physical NIC would collide.
      '';
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

          # Disable systemd's 90s DefaultDeviceTimeoutSec inside initrd.
          # SSH-unlock means a human types the passphrase, which often
          # exceeds 90s; and on LUKS+LVM stacks the LVM device-timeout
          # races the LUKS open even with fast passphrase entry, dropping
          # the boot into emergency.target. See NixOS 26.05 release notes.
          settings.Manager.DefaultDeviceTimeoutSec = "infinity";

          # Pull network-online.target into the initrd boot graph. Without
          # something `wants`ing it, systemd-networkd-wait-online.service
          # never runs (it is wantedBy=network-online.target, not
          # initrd.target), so DHCP completion isn't waited on and the link
          # may not be ready by the time the LUKS prompt resolves on the
          # console — leaving SSH unreachable.
          services.initrd-unlock-await-network = {
            description = "Pull network-online.target into initrd";
            wantedBy = [ "initrd.target" ];
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "/bin/true";
            };
          };

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

          # Per NixOS 26.05 release notes: `cryptsetup-askpass` is gone under
          # systemd-initrd; the supported way to drive the unlock from an SSH
          # session is to run `systemctl default`, which itself acts as a
          # password agent when attached to a TTY. ForceCommand applies to
          # every key, so callers don't have to remember the `command="…"`
          # prefix in authorizedKeys.
          extraConfig = ''
            ForceCommand systemctl default
          '';

          # `ssh-keygen -t ed25519 -N "" -f /path/to/ssh_host_ed25519_key`
          # hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];

          # authorizedKeys = config.sshkeys.pavel-all
          #   ++ [ config.sshkeys.initrd ];
        };
      };
    };
  };

}
