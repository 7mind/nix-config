{ inputs, lib, ... }:

{
  imports = [
    inputs.nixos-raspberrypi.nixosModules.raspberry-pi-5.base
    inputs.nixos-raspberrypi.nixosModules.raspberry-pi-5.page-size-16k
    inputs.nixos-raspberrypi.nixosModules.raspberry-pi-5.bluetooth
  ];

  nixpkgs.overlays = [
    inputs.nixos-raspberrypi.overlays.vendor-pkgs
    # Skip overlays.pkgs — it replaces all ffmpeg/libcamera/kodi/vlc
    # variants with RPi-specific builds that are expensive to compile
    # and unnecessary on a headless server.
  ];

  # Recommended by nixos-raspberrypi for new RPi 5 installs
  boot.loader.raspberry-pi.bootloader = "kernel";

  # The rpi-bcm2712 kernel caps ARCH_MMAP_RND_BITS_MAX at 30 (16K pages),
  # below the nixpkgs default of 33. Without this, systemd-sysctl fails on
  # activation with EINVAL when writing vm.mmap_rnd_bits.
  boot.kernel.sysctl."vm.mmap_rnd_bits" = lib.mkForce 30;

  # Enable PCIe Gen3 for NVMe (default is Gen2)
  hardware.raspberry-pi.config.all.base-dt-params.pciex1_gen = {
    enable = true;
    value = 3;
  };

  smind = {
    zfs.enable = false;
    kernel.sane-defaults.enable = false;
  };
}
