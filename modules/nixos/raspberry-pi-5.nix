{ inputs, lib, ... }:

{
  imports = [
    inputs.nixos-raspberrypi.nixosModules.raspberry-pi-5.base
    inputs.nixos-raspberrypi.nixosModules.raspberry-pi-5.page-size-16k
    inputs.nixos-raspberrypi.nixosModules.raspberry-pi-5.bluetooth
  ];

  nixpkgs.overlays = [
    inputs.nixos-raspberrypi.overlays.vendor-pkgs
    inputs.nixos-raspberrypi.overlays.pkgs
    (final: prev: {
      # The vendor-pkgs overlay globally sets libcamera = libcamera_rpi.
      # Override pipewire to not depend on it — raspi5m is a headless
      # server with no camera, and libcamera_rpi is expensive to build.
      pipewire = prev.pipewire.override { libcamera = null; };
    })
  ];

  # Recommended by nixos-raspberrypi for new RPi 5 installs
  boot.loader.raspberry-pi.bootloader = "kernel";

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
