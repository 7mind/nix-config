{ config, lib, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
    ];

  networking.hostId = "8a9c7614";
  networking.hostName = "pavel-am5";

  networking.networkmanager.enable = true;
  programs.virt-manager.enable = true;

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
      extraGroups = [ "wheel" "libvirtd" "plugdev" "disk" ];
      openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKA1LYgjfuWSxa1lZRCebvo3ghtSAtEQieGlVCknF8f pshirshov@7mind.io" ];
    };
  };

  home-manager.users.pavel = import ./home-pavel.nix;
  home-manager.users.root = import ./home-root.nix;

  environment.systemPackages = with pkgs; [
  ];

  smind = {
    roles.desktop.generic-gnome = true;

    security.sudo.wheel-permissive-rules = true;
    security.sudo.wheel-passwordless = true;

    zfs.email.enable = false;
    zfs.email.to = "team@7mind.io";
    zfs.email.sender = "zed-vm@home.7mind.io";

    zfs.initrd-unlock.enable = true;
    zfs.initrd-unlock.interface = "enp8s0";

    ssh.permissive = true;

    kernel.hack-rtl8125.enable = true;

    hw.uhk-keyboard.enable = true;
    hw.trezor.enable = true;
    hw.ledger.enable = true;
  };
}
