{ config, cfg-meta, lib, pkgs, cfg-const, import_if_exists, import_if_exists_or, cfg-flakes, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      (import_if_exists_or "${cfg-meta.paths.secrets}/pavel/age-rekey.nix" (import "${cfg-meta.paths.modules}/age-dummy.nix"))
    ];

  nixpkgs.config.permittedInsecurePackages = [
    # "fluffychat-linux-1.23.0"
    # "olm-3.2.16"
    "python3.13-ecdsa-0.19.1"
  ];

  nix = {
    settings = {
      max-jobs = 2;
      cores = 12;
      allowed-users = [ "root" "pavel" ];
      trusted-users = [ "root" "pavel" ];
    };
  };

  services = {
    samba = {
      # add user: sudo smbpasswd -a pavel
      # change password: sudo smbpasswd -U pavel
      # connect: smbclient //pavel-am5/Home
      enable = true;
      openFirewall = true;


      settings = {
        global = {
          security = "user";
          "workgroup" = "AD";
          "guest account" = "nobody";
          "map to guest" = "bad user";
        };

        Home = {
          path = "/home/pavel";
          "vfs objects" = "streams_xattr";
          "public" = "no";
          "browseable" = "yes";
          "writeable" = "yes";
          "printable" = "no";
          "guest ok" = "no";
          "read list" = "pavel";
          "write list" = "pavel";
          "force group" = "users";
          #"force directory mode" = "0770";
          #"force create mode" = "0660";
          "comment" = "Home directory";
        };
      };
    };

    samba-wsdd = {
      enable = true;
      openFirewall = true;
    };
  };

  systemd.network = {
    links = {
      "10-eth-tmp.link" = {
        matchConfig.PermanentMACAddress = "a0:ad:9f:1e:c6:59";
        linkConfig.Name = "eth-tmp";
      };
    };

    networks = {
      "20-${config.smind.net.main-bridge}" = {
        ipv6AcceptRAConfig = {
          Token = "::0020";
        };
      };

      "20-eth-tmp" = {
        name = "eth-tmp";
        DHCP = "yes";

        linkConfig = {
          RequiredForOnline = "no";
        };

        networkConfig = {
          IPv6PrivacyExtensions = "no";
          DHCPPrefixDelegation = "yes";
          IPv6AcceptRA = "yes";
          LinkLocalAddressing = "yes";
        };

        dhcpV4Config = {
          SendHostname = true;
          Hostname = "${config.networking.hostName}-2.${config.networking.domain}";
          UseDomains = true;
        };

        dhcpV6Config = {
          SendHostname = true;
          Hostname = "${config.networking.hostName}-2-ipv6.${config.networking.domain}";
          UseDomains = true;
        };
      };
    };

  };




  programs.winbox = {
    enable = true;
    package = # https://github.com/NixOS/nixpkgs/issues/408853
      (pkgs.winbox4.overrideAttrs (drv:
        {
          buildInputs = drv.buildInputs ++ [ pkgs.makeWrapper ];
          postFixup = ''
            wrapProgram $out/bin/WinBox --set "QT_QPA_PLATFORM" "xcb"
          '';
        }));
  };

  smind = {
    roles.desktop.generic-gnome = true;

    locale.ie.enable = true;

    security.sudo.wheel-permissive-rules = true;
    security.sudo.wheel-passwordless = true;

    zfs.email.enable = true;
    host.email.to = "team@7mind.io";
    host.email.sender = "${config.networking.hostName}@home.7mind.io";

    zfs.initrd-unlock.enable = true;
    zfs.initrd-unlock.macaddr = "d0:94:66:55:aa:ab";

    net.main-interface = "eth-main";

    net.main-macaddr = "a0:ad:9f:1c:9e:98"; # marvel AQC113, 10g
    # net.main-macaddr = "a0:ad:9f:1e:c6:59"; # intel I226-V, 2.5g

    net.main-bridge-macaddr = "d0:94:66:55:aa:11";
    net.tailscale.enable = true;

    ssh.mode = "safe";

    hw.uhk-keyboard.enable = true;
    # hw.trezor.enable = true;
    hw.ledger.enable = true;
    hw.bluetooth.enable = true;

    isDesktop = true;
    hw.cpu.isAmd = true;
    hw.amd.gpu.enable = true;

    bootloader.systemd-boot.enable = true;
    bootloader.lanzaboote.enable = false;

    llm.enable = true;
    containers.docker.enable = true;
    infra.nix-build.enable = true;

    iperf.enable = true;
    iperf.protected.server.enable = false;
    iperf.protected.client.enable = true;

    desktop.cosmic.enable = true;
    # desktop.cosmic.minimal-keybindings = true;

    audio.quirks = {
      enable = true;
      devices = [
        {
          name = "Jabra Link 390";
          vendorId = "0b0e";
          productId = "2e56";
          formFactor = "headset";
        }
      ];
    };

    audio.autoswitch = {
      enable = true;
      formFactors = [ "headset" "headphone" ];
    };
  };

  boot.kernelPatches = [
    {
      name = "mediatek-mt7927-bluetooth";
      patch = pkgs.writeText "mt7927-bt.patch" ''
        --- a/drivers/bluetooth/btusb.c
        +++ b/drivers/bluetooth/btusb.c
        @@ -672,6 +672,8 @@ static const struct usb_device_id quirks_table[] = {
         	{ USB_DEVICE(0x0489, 0xe0e4), .driver_info = BTUSB_MEDIATEK |
         						     BTUSB_WIDEBAND_SPEECH },
         	{ USB_DEVICE(0x0489, 0xe0f1), .driver_info = BTUSB_MEDIATEK |
        +						     BTUSB_WIDEBAND_SPEECH },
        +	{ USB_DEVICE(0x0489, 0xe13a), .driver_info = BTUSB_MEDIATEK |
         						     BTUSB_WIDEBAND_SPEECH },
         	{ USB_DEVICE(0x0489, 0xe0f2), .driver_info = BTUSB_MEDIATEK |
         						     BTUSB_WIDEBAND_SPEECH },
      '';
    }
  ];

  networking.hostId = "8a9c7614";
  networking.hostName = cfg-meta.hostname;
  networking.domain = "home.7mind.io";
  networking.useDHCP = false;
  networking.firewall = {
    allowedTCPPorts = [ 8234 ];
  };

  programs.steam.enable = true;

  boot.initrd = {
    kernelModules = [ "atlantic" "igc" ];

    network = {
      ssh = {
        # `ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key`
        hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
        authorizedKeys = cfg-const.ssh-keys-pavel;
      };
    };
  };


  boot.loader = {
    systemd-boot = {
      windows = {
        "11".efiDeviceHandle = "HD1b";
      };
    };
  };

  users = {
    users.root.password = "nixos";

    users.pavel = {
      isNormalUser = true;
      home = "/home/pavel";
      extraGroups = [
        "wheel"
        "audio"
        "video"
        "render"
        "cdrom"
        "disk"
        "networkmanager"
        "plugdev"
        "input"
        "libvirtd"
        "qemu"
        "qemu-libvirtd"
        "kvm"
        "uinput"
        # "adbusers"
        # "docker"
        # "corectrl"
        # "wireshark"
        "ssh-users"
        "podman"
        "ollama"
      ];
      openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel;
    };

    users.test = {
      isNormalUser = true;
      home = "/home/test";
      initialPassword = "test";
      extraGroups = [
        "wheel"
        "audio"
        "video"
        "render"
        "cdrom"
        "disk"
        "networkmanager"
        "plugdev"
        "input"
        "libvirtd"
        "qemu"
        "qemu-libvirtd"
        "kvm"
        "uinput"
        "adbusers"
        # "docker"
        # "corectrl"
        # "wireshark"
        "ssh-users"
        "podman"
        "ollama"
      ];
    };

  };

  programs.adb.enable = true;
  # services.udev.packages = [
  #   pkgs.android-udev-rules
  # ];

  home-manager.users.pavel = import ./home-pavel.nix;
  home-manager.users.root = import ./home-root.nix;

  environment.systemPackages = with pkgs; [

  ];

  # doesn't work
  # systemd.tmpfiles.rules =
  #   let
  #     xml = ''
  #         <monitors version="2">
  #         <configuration>
  #           <layoutmode>logical</layoutmode>
  #           <logicalmonitor>
  #             <x>5120</x>
  #             <y>0</y>
  #             <scale>1.5</scale>
  #             <monitor>
  #               <monitorspec>
  #                 <connector>DP-2</connector>
  #                 <vendor>PHL</vendor>
  #                 <product>PHL 329P9</product>
  #                 <serial>0x000004bc</serial>
  #               </monitorspec>
  #               <mode>
  #                 <width>3840</width>
  #                 <height>2160</height>
  #                 <rate>59.997</rate>
  #               </mode>
  #             </monitor>
  #           </logicalmonitor>
  #           <logicalmonitor>
  #             <x>2560</x>
  #             <y>0</y>
  #             <scale>1.5</scale>
  #             <primary>yes</primary>
  #             <monitor>
  #               <monitorspec>
  #                 <connector>DP-1</connector>
  #                 <vendor>AOC</vendor>
  #                 <product>AG324UWS4R4B</product>
  #                 <serial>QVJN2JA000291</serial>
  #               </monitorspec>
  #               <mode>
  #                 <width>3840</width>
  #                 <height>2160</height>
  #                 <rate>144.000</rate>
  #               </mode>
  #             </monitor>
  #           </logicalmonitor>
  #           <logicalmonitor>
  #             <x>0</x>
  #             <y>0</y>
  #             <scale>1.5</scale>
  #             <monitor>
  #               <monitorspec>
  #                 <connector>DP-3</connector>
  #                 <vendor>HPN</vendor>
  #                 <product>HP Z32</product>
  #                 <serial>CN4041057P</serial>
  #               </monitorspec>
  #               <mode>
  #                 <width>3840</width>
  #                 <height>2160</height>
  #                 <rate>59.997</rate>
  #               </mode>
  #             </monitor>
  #           </logicalmonitor>
  #         </configuration>
  #       </monitors>
  #     '';
  #   in
  #   [
  #     # "f+ /run/gdm/.config/monitors.xml - gdm gdm - ${xml}"
  #     (
  #       let monitorsXml = pkgs.writeText "gdm-monitors.xml" xml;
  #       in "L+ /run/gdm/.config/monitors.xml - - - - ${monitorsXml}"
  #     )
  #   ];


}
