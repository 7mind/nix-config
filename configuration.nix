{ config, lib, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ./modules/nix/gnome.nix
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
  nixpkgs.config.allowUnfree = true;

  boot.supportedFilesystems = [ "zfs" ];
  networking.hostId = "8a9c7614";
  networking.hostName = "freshnix";

  boot.loader.efi.canTouchEfiVariables = false;

  boot.kernelModules = [ "r8169" ];

  boot.initrd = {
    kernelModules = [ "r8169" ];

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
          networks.tmpnet = {
            enable = true;
            name = "enp8s0";
            DHCP = "yes";
            dhcpV4Config = {
              SendHostname = true;
              Hostname = "pavel-am5-initrd.home.7mind.io";
            };
          };
        };
      };


    network = {
      enable = true;

      ssh = {
        enable = true;
        port = 22;
        hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
        authorizedKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKA1LYgjfuWSxa1lZRCebvo3ghtSAtEQieGlVCknF8f pshirshov@7mind.io" ];
      };
    };
  };

  boot.loader.grub = {
    enable = true;
    useOSProber = true;
    memtest86.enable = true;

    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
    extraEntries = ''
      menuentry "Firmware setup" {
          fwsetup
      }
    '';
  };

  boot.kernelPackages = pkgs.linuxKernel.packages.linux_6_12;
  boot.kernelPatches = [
    {
      # https://github.com/NixOS/nixpkgs/issues/350679
      name = "rtl8125";
      patch = pkgs.fetchurl {
        url =
          "https://github.com/torvalds/linux/commit/f75d1fbe7809bc5ed134204b920fd9e2fc5db1df.patch";
        sha256 = "sha256-5E2TAGDLQnEvQv09Di/RcMM/wYosdjApOaDgUhIHtYM=";
      };
    }
    {
      # https://lore.kernel.org/netdev/d49e275f-7526-4eb4-aa9c-31975aecbfc6@gmail.com/#related
      name = "rtl8125-hack";
      patch = pkgs.fetchurl {
        url =
          "https://gist.githubusercontent.com/pshirshov/0896092630775b700c718e110662439a/raw/7d7dbbc52e63f4ee3beff5c6b23393ee07625287/rtl.patch";
        sha256 = "sha256-AFP3EtuYJt5NCzFYRPL/6ePS+O3aNtifZTS5y0ZSv1M=";
      };
    }
  ];

  networking.networkmanager.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
    };
    openFirewall = true;
  };


  programs.zsh.enable = true;
  environment.shells = with pkgs; [ zsh ];
  users = {
    defaultUserShell = pkgs.zsh;

    users.root.password = "nixos";
    users.pavel = {
      isNormalUser = true;
      home = "/home/pavel";
      extraGroups = [ "wheel" "libvirtd" "plugdev" "disk" ];
      openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKA1LYgjfuWSxa1lZRCebvo3ghtSAtEQieGlVCknF8f pshirshov@7mind.io" ];
    };
  };

  boot.kernelParams = [ ];

  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
    cpu.amd.updateMicrocode = true;
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

  nix = {
    package = pkgs.nixVersions.stable;
    gc.automatic = true;
    gc.options = "--delete-older-than 8d";
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
    optimise.automatic = true;
    settings = {
      connect-timeout = 1;
      keep-going = true;
      use-xdg-base-directories = true;
    };
  };



  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;

  home-manager.users.pavel = import ./home-pavel.nix;
}
