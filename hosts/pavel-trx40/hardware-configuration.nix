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

  # ZFS root layout preserved from the previous install on this machine.
  # The pool name and dataset paths must match what already exists on
  # disk; only adjust UUIDs/devices below if the partitions are
  # re-created.
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

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
