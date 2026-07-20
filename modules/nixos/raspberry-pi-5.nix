{ inputs, lib, pkgs, ... }:

{
  imports = [
    inputs.nixos-raspberrypi.nixosModules.raspberry-pi-5.base
    inputs.nixos-raspberrypi.nixosModules.raspberry-pi-5.page-size-16k
    inputs.nixos-raspberrypi.nixosModules.raspberry-pi-5.bluetooth
  ];

  # nixpkgs 26.11 removed `stdenv.hostPlatform.linux-kernel` and now sources the
  # kernel image name (`kernelFile`) and DTB flag (`hardware.deviceTree.enable`)
  # from `target`/`buildDTBs` passthru attrs on the kernel derivation instead.
  # nixos-raspberrypi `develop` reads those attrs on nixpkgs >= 26.11, but its
  # kernel is built from the flake's own pinned (pre-removal) nixpkgs, which does
  # not attach them — so evaluation aborts with `attribute 'target'/'buildDTBs'
  # missing`. Re-attach the canonical aarch64 values. These are eval-only: the
  # derivation and its out-path are unchanged, so the upstream-cached kernel is
  # reused (no rebuild). Drop once nixos-raspberrypi's pinned nixpkgs provides
  # these passthru attrs itself.
  boot.kernelPackages =
    let
      kp = inputs.nixos-raspberrypi.packages.${pkgs.stdenv.hostPlatform.system}.linuxPackages_rpi5;
    in
    lib.mkForce (kp.extend (_: super: {
      # overrideAttrs (not //): boot.kernelPackages' own apply re-runs
      # `kernel.override`, which rebuilds the derivation and would drop plain
      # attrs; overrideAttrs composes through `.override`, so the passthru
      # survives. passthru-only change keeps the out-path (no rebuild).
      kernel = super.kernel.overrideAttrs (old: {
        passthru = (old.passthru or { }) // {
          target = "Image";
          buildDTBs = true;
        };
      });
    }));

  nixpkgs.overlays = [
    inputs.nixos-raspberrypi.overlays.vendor-pkgs
    # Skip overlays.pkgs — it replaces all ffmpeg/libcamera/kodi/vlc
    # variants with RPi-specific builds that are expensive to compile
    # and unnecessary on a headless server.
  ];

  # Pull the upstream-built kernel and vendor packages from nixos-raspberrypi's
  # binary cache instead of compiling them locally. The flake input declares
  # this cache in its own `nixConfig`, but nix ignores `nixConfig` from inputs
  # (only the root flake's is honored) — so wire it in explicitly here, scoped
  # to the hosts that actually consume those out-paths. Merges with the default
  # substituters and the attic cache; connect-timeout is intentionally left to
  # the attic module to avoid a conflicting single-value assignment.
  nix.settings = {
    substituters = [ "https://nixos-raspberrypi.cachix.org" ];
    trusted-public-keys = [ "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=" ];
  };

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
    hw.cpu.isArm = true;
  };
}
