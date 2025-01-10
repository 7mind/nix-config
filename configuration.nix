{ config, lib, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./modules/nix/gnome.nix
      ./modules/nix/kernel.nix
      ./modules/nix/router.nix
      ./modules/nix/zswap.nix
      ./modules/nix/zfs.nix
      ./modules/nix/zfs-ssh-initrd.nix
      ./modules/nix/grub.nix
      ./modules/nix/nix.nix
      ./modules/nix/zsh.nix

      ./modules/nix/realtek-kernel-hack.nix
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
  networking.hostName = "freshnix";

  boot.initrd = {
    systemd =
      {
        network = {
          networks.bootnet = {
            name = "enp8s0";
            dhcpV4Config = {
              Hostname = "pavel-am5-initrd.home.7mind.io";
            };
          };
        };
      };


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
}
