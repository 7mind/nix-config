{ pkgs, ... }:

{
  nixpkgs.config.allowUnfree = true;


  boot.supportedFilesystems = [ "zfs" ];
  networking.hostId = "__ZFSID__";
  networking.hostName = "freshnix";

  boot.loader.efi.canTouchEfiVariables = false;
  boot.initrd.systemd.enable = true;

  boot.loader.grub = {
    enable = true;
    #version = 2;
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
  users = {
    users.root.password = "nixos";
  };
  boot.kernelParams = [ "boot.shell_on_fail" "boot.trace" ];
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
  ];

}
