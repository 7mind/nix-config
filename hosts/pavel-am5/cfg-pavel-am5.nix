{ config, cfg-meta, import_if_exists, cfg-const, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      "${cfg-meta.paths.secrets}/pavel/age-rekey.nix"
      "${cfg-meta.paths.secrets}/pavel/age-secrets.nix"
    ];

  nixpkgs.config.permittedInsecurePackages = [
    "fluffychat-linux-1.23.0"
    "olm-3.2.16"
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

  smind = {
    roles.desktop.generic-gnome = true;

    locale.ie.enable = true;

    security.sudo.wheel-permissive-rules = true;
    security.sudo.wheel-passwordless = true;

    zfs.email.enable = true;
    host.email.to = "team@7mind.io";
    host.email.sender = "${config.networking.hostName}@home.7mind.io";

    zfs.initrd-unlock.enable = true;

    net.main-interface = "enp8s0";
    net.main-macaddr = "d0:94:66:55:aa:11";
    net.tailscale.enable = true;

    ssh.permissive = false;
    ssh.safe = true;

    hw.uhk-keyboard.enable = true;
    hw.trezor.enable = true;
    hw.ledger.enable = true;
    hw.bluetooth.enable = true;

    isDesktop = true;
    hw.cpu.isAmd = true;
    hw.rocm.enable = true;

    systemd-boot.enable = true;
    lanzaboote.enable = false;

    kernel.hack-rtl8125.enable = false;
    llm.enable = true;
    docker.enable = true;
    infra.nix-build.enable = true;
  };

  age.rekey = {
    hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM1VvmTzQX/bvLjKEyDfGWdxGdt+3ZSy7/f6r5YAsvtS";
  };

  networking.hostId = "8a9c7614";
  networking.hostName = cfg-meta.hostname;
  networking.domain = "home.7mind.io";

  boot.initrd = {
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
  };

  home-manager.users.pavel = import ./home-pavel.nix;
  home-manager.users.root = import ./home-root.nix;

  # environment.systemPackages = with pkgs; [

  # ];

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
