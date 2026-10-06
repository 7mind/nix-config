{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # TRX40 / Threadripper 3970x: AHCI for SATA, NVMe for storage, USB HID
  # for the boot-time keyboard, and r8169 for the on-board Realtek NIC.
  # dm-snapshot is required in initrd for the LVM root/swap on the fresh
  # 2TB layout (vg-nixos on nvme0n1p1).
  boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "nvme" "usbhid" ];
  boot.initrd.kernelModules = [ "r8169" "dm-snapshot" ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # TRX40 chipset workaround: PCIe ASPM produces spurious PME interrupts
  # ("pcieport ... PME: spurious native interrupt") which spam dmesg and
  # can stall a few PCIe devices. Disabling ASPM is harmless on a
  # desktop-class box.
  boot.kernelParams = [ "pcie_aspm=off" ];

  # Fresh 2TB CT2000T710SSD8 layout (basic NixOS install, 2026-10-06):
  # single ext4 root on LVM (vg-nixos/lv-root); /nix and /home live on
  # the same filesystem — no separate LVs. Revisit if we return to ZFS.
  fileSystems."/" = {
    device = "/dev/mapper/vg--nixos-lv--root";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/C42E-2E55";
    fsType = "vfat";
    options = [ "fmask=0022" "dmask=0022" ];
  };

  # Random-key encrypted swap on the Samsung 970 EVO Plus keeps its old
  # role (ephemeral dm-crypt, fresh /dev/urandom key each boot, `nofail`
  # so a missing disk never blocks boot). The LVM swap on the fresh 2TB
  # disk stays as a lower-priority fallback.
  swapDevices = [
    {
      device = "/dev/mapper/vg--nixos-lv--swap";
    }
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
