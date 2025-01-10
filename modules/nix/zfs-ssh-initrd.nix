{ pkgs
, assertHasStringAttr
, ...
}:
{
  assertions = [
    (assertHasStringAttr
      {
        source = "zfs-ssh-initrd.nix";
        base = "boot.initrd.systemd.network.networks.bootnet";
        name = "name";
        msg = "should be set to a network device name";
      })
    (assertHasStringAttr
      {
        source = "zfs-ssh-initrd.nix";
        base = "boot.initrd.systemd.network.networks.bootnet.dhcpV4Config";
        name = "Hostname";
        msg = "should be set to a special hostname for initrd";
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

          networks.bootnet = {
            enable = true;
            # name = "enpXXX";
            DHCP = "yes";
            dhcpV4Config = {
              SendHostname = true;
              #Hostname = "HOST-initrd.home.7mind.io";
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
}


