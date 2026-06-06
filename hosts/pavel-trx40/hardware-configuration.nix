{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # TRX40 / Threadripper 3970x: AHCI for SATA, NVMe for storage, USB HID
  # for the boot-time keyboard, and r8169 for the on-board Realtek NIC
  # which we want available in initrd for SSH-based ZFS unlock.
  boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "nvme" "usbhid" ];
  boot.initrd.kernelModules = [ "r8169" ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # TRX40 chipset workaround: PCIe ASPM produces spurious PME interrupts
  # ("pcieport ... PME: spurious native interrupt") which spam dmesg and
  # can stall a few PCIe devices. Disabling ASPM is harmless on a
  # desktop-class box.
  boot.kernelParams = [ "pcie_aspm=off" ];

  # ZFS root layout preserved from the previous install — pool name and
  # dataset paths must match on-disk; only adjust UUIDs/devices if the
  # partitions are re-created.
  fileSystems."/" = {
    device = "zroot/root";
    fsType = "zfs";
  };

  fileSystems."/nix" = {
    device = "zroot/root/nix";
    fsType = "zfs";
  };

  fileSystems."/home" = {
    device = "zroot/root/home";
    fsType = "zfs";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/837B-9A49";
    fsType = "vfat";
    options = [ "fmask=0022" "dmask=0022" ];
  };

  # Random-key encrypted swap on the Samsung 970 EVO Plus — ephemeral by
  # design: dm-crypt opens it with a fresh /dev/urandom key each boot, so
  # no persistent state. `nofail` keeps a missing/failed disk from blocking
  # boot; the 32G zd0 zvol swap remains as a lower-priority fallback.
  swapDevices = [
    {
      device = "/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_Plus_250GB_S4EUNX0R971112P-part1";
      randomEncryption = {
        enable = true;
        cipher = "aes-xts-plain64";
        allowDiscards = true;
      };
      priority = 100;
      options = [ "nofail" ];
    }
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
