{ pkgs, ... }:

{
  nixpkgs.config.allowUnfree = true;
  nix.extraOptions = ''
    experimental-features = nix-command flakes
  '';

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

  boot.kernelPackages = pkgs.linuxKernel.packages.linux_6_13;
  boot.kernelPatches = [ ];

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
