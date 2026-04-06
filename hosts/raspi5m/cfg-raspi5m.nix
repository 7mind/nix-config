{ config, cfg-meta, lib, pkgs, cfg-const, import_if_exists, cfg-flakes, inputs, ... }:

{
  # Quick initial setup:
  # nix build github:nvmd/nixos-raspberrypi#installerImages.rpi5
  # zstd -d --stdout "$(readlink -f result)/sd-image/nixos-installer-rpi5-kernel.img.zst" | sudo dd of=/dev/sdb bs=4M status=progress conv=fsync
  imports = [
    ./hardware-configuration.nix
    inputs.nixos-raspberrypi.nixosModules.raspberry-pi-5.base
    inputs.nixos-raspberrypi.nixosModules.raspberry-pi-5.page-size-16k
    inputs.nixos-raspberrypi.nixosModules.raspberry-pi-5.bluetooth
  ];

  nixpkgs.overlays = [
    inputs.nixos-raspberrypi.overlays.vendor-pkgs
    inputs.nixos-raspberrypi.overlays.pkgs
    (final: prev: {
      # Workaround for libcamera-rpi build error: unknown option "rpi-awb-nn"
      libcamera_rpi = prev.libcamera_rpi.overrideAttrs (old: {
        mesonFlags = lib.filter (x: !lib.hasInfix "rpi-awb-nn" (if lib.isString x then x else "")) old.mesonFlags;
      });
    })
  ];

  networking.hostName = cfg-meta.hostname;
  networking.domain = "home.7mind.io";

  # Recommended by the project for new RPi 5 installs
  boot.loader.raspberry-pi.bootloader = "kernel";

  services.openssh.enable = true;

  smind = {
    roles.server.generic = true;
    home-manager.enable = true;

    zfs.enable = false;
    kernel.sane-defaults.enable = false;

    nix.nix-impl = "determinate";
    age.enable = true;
    ssh.mode = "safe";

    security.sudo.wheel-permissive-rules = true;
    security.sudo.wheel-passwordless = true;

    net.mode = "networkmanager";
    net.tailscale.enable = true;

    host.email.to = "team@7mind.io";
    host.email.sender = "${config.networking.hostName}@home.7mind.io";

    services.zwave-js-ui.enable = true;
  };

  age.rekey = {
    hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBQppBMV2SUZNeKqIP/OlXjuYMYec0xP0ckVyce2l6LY";
  };

  networking.hostId = "deadbeef";

  services.udev.extraRules = ''
    SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", ATTRS{serial}=="3041f4e6a689ef118875b095ef8776e9", SYMLINK+="ttyZigbee"
    SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", ATTRS{serial}=="1c8673aa0322f0119a325d8fb887153e", SYMLINK+="ttyZWave"
  '';

  users = {
    users.root.initialPassword = "nixos";
    users.root.openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel;

    users.pavel = {
      isNormalUser = true;
      linger = true;
      home = "/home/pavel";
      extraGroups = [
        "wheel"
        "audio"
        "video"
        "render"
        "input"
        "disk"
        "networkmanager"
        "ssh-users"
      ];
      initialPassword = "nixos";
      openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel;
    };
  };

  home-manager.users.pavel = import ./home-pavel.nix;
  home-manager.users.root = import ./home-root.nix;
}
