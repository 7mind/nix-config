{ config, lib, pkgs, cfg-meta, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
    ];

  networking.hostId = "8a9c7614";
  networking.hostName = cfg-meta.hostname;
  networking.domain = "home.7mind.io";

  networking.networkmanager.enable = true;

  boot.initrd = {
    network = {
      ssh = {
        hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
        authorizedKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKA1LYgjfuWSxa1lZRCebvo3ghtSAtEQieGlVCknF8f pshirshov@7mind.io" ];
      };
    };
  };

  boot.loader = {
    systemd-boot = {
      windows = {
        "11".efiDeviceHandle = "HD0b";
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
        # "ssh-users"
      ];
      openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKA1LYgjfuWSxa1lZRCebvo3ghtSAtEQieGlVCknF8f pshirshov@7mind.io" ];
    };
  };

  home-manager.users.pavel = import ./home-pavel.nix;
  home-manager.users.root = import ./home-root.nix;

  environment.systemPackages = with pkgs; [

  ];

  systemd.tmpfiles.rules =
    let
      xml = ''
          <monitors version="2">
          <configuration>
            <layoutmode>logical</layoutmode>
            <logicalmonitor>
              <x>5120</x>
              <y>0</y>
              <scale>1.5</scale>
              <monitor>
                <monitorspec>
                  <connector>DP-2</connector>
                  <vendor>PHL</vendor>
                  <product>PHL 329P9</product>
                  <serial>0x000004bc</serial>
                </monitorspec>
                <mode>
                  <width>3840</width>
                  <height>2160</height>
                  <rate>59.997</rate>
                </mode>
              </monitor>
            </logicalmonitor>
            <logicalmonitor>
              <x>2560</x>
              <y>0</y>
              <scale>1.5</scale>
              <primary>yes</primary>
              <monitor>
                <monitorspec>
                  <connector>DP-1</connector>
                  <vendor>AOC</vendor>
                  <product>AG324UWS4R4B</product>
                  <serial>QVJN2JA000291</serial>
                </monitorspec>
                <mode>
                  <width>3840</width>
                  <height>2160</height>
                  <rate>144.000</rate>
                </mode>
              </monitor>
            </logicalmonitor>
            <logicalmonitor>
              <x>0</x>
              <y>0</y>
              <scale>1.5</scale>
              <monitor>
                <monitorspec>
                  <connector>DP-3</connector>
                  <vendor>HPN</vendor>
                  <product>HP Z32</product>
                  <serial>CN4041057P</serial>
                </monitorspec>
                <mode>
                  <width>3840</width>
                  <height>2160</height>
                  <rate>59.997</rate>
                </mode>
              </monitor>
            </logicalmonitor>
          </configuration>
        </monitors>
      '';
    in
    [
      # "f+ /run/gdm/.config/monitors.xml - gdm gdm - ${xml}"
      (
        let monitorsXml = pkgs.writeText "gdm-monitors.xml" xml;
        in "L+ /run/gdm/.config/monitors.xml - - - - ${monitorsXml}"
      )
    ];

  smind = {
    roles.desktop.generic-gnome = true;

    locale.ie.enable = true;

    security.sudo.wheel-permissive-rules = true;
    security.sudo.wheel-passwordless = true;

    zfs.email.enable = false;
    host.email.to = "team@7mind.io";
    host.email.sender = "${config.networking.hostName}@home.7mind.io";

    zfs.initrd-unlock.enable = true;

    net.main-interface = "enp8s0";

    ssh.permissive = true;

    kernel.hack-rtl8125.enable = true;

    hw.uhk-keyboard.enable = true;
    hw.trezor.enable = true;
    hw.ledger.enable = true;

    isDesktop = true;
    hw.cpu.isAmd = true;
  };
}
