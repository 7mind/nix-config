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
