{ config, lib, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
    ];

  programs.nix-ld = {
    enable = true;
    package = pkgs.nix-ld-rs;
    libraries = with pkgs; [ ];
  };

  system.stateVersion = "25.05";

  #environment.variables = {COSMIC_DISABLE_DIRECT_SCANOUT = "1";};
  #{
  #            nix.settings = {
  #              substituters = [ "https://cosmic.cachix.org/" ];
  #              trusted-public-keys = [ "cosmic.cachix.org-1:Dya9IyXD4xdBehWjrkPv6rtxpmMdRel02smYzA85dPE=" ];
  #            };
  #                          services.desktopManager.cosmic.enable = true;
  #            services.displayManager.cosmic-greeter.enable = true;
  #          }

  networking.hostId = "8a9c7614";
  networking.hostName = "pavel-am5";

  boot.initrd = {
    network = {
      ssh = {
        hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
        authorizedKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKA1LYgjfuWSxa1lZRCebvo3ghtSAtEQieGlVCknF8f pshirshov@7mind.io" ];
      };
    };
  };

  networking.networkmanager.enable = true;

  users = {
    users.root.password = "nixos";

    users.pavel = {
      isNormalUser = true;
      home = "/home/pavel";
      extraGroups = [ "wheel" "libvirtd" "plugdev" "disk" ];
      openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKA1LYgjfuWSxa1lZRCebvo3ghtSAtEQieGlVCknF8f pshirshov@7mind.io" ];
    };
  };

  environment.systemPackages = with pkgs; [
    mc
    nano

    gptfdisk
    parted
    nvme-cli
    efibootmgr

    kitty.terminfo
    nixpkgs-fmt

    nix-ld-rs
  ];

  programs.virt-manager.enable = true;

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;

  home-manager.users.pavel = import ./home-pavel.nix;
  home-manager.users.root = import ./home-root.nix;

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
  };
}
