{ config, cfg-meta, lib, pkgs, cfg-const, import_if_exists, cfg-flakes, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  nix = {
    settings = {
      max-jobs = 2;
      cores = 12; # Assuming AM4 system has at least 6-12 cores
      allowed-users = [ "root" "pavel" ];
      trusted-users = [ "root" "pavel" ];
    };
  };

  boot.initrd.luks.devices."cryptroot".device = "/dev/disk/by-uuid/3d9e2116-2c30-4143-9095-8e4372062008";

  # Initrd SSH host key — provisioned out-of-band on the running host
  # before the first switch:
  #   sudo mkdir -p /etc/secrets/initrd
  #   sudo ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key
  # systemd-initrd serves the LUKS passphrase prompt; ssh in as `root@<host>`
  # and the smind.initrd-unlock module replaces root's login shell with
  # `systemd-tty-ask-password-agent --watch`.
  boot.initrd.network.ssh = {
    hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
    authorizedKeys = cfg-const.ssh-keys-pavel;
  };

  smind = {
    host.owner = "pavel";
    host.email.to = "team@7mind.io";
    host.email.sender = "${config.networking.hostName}@home.7mind.io";
    roles.desktop.generic-gnome = true;
    roles.server.llm-worker.enable = true; # creates the `llm` user + agenix-managed ssh key

    hw.cpu.isAmd = true;
    hw.amd.gpu.enable = true;

    age.masterIdentity.pubkey = "age1ax4x0pwe00clawkp5zn7qdf5e2tvuu0echvachd0pv5hm8hq9qnswqpzek";

    # testbench is an llm-worker, not a workstation: pavel doesn't run
    # `git push` / SBT / OpenRouter from here. Skip pavel's owner-secrets
    # to avoid rekeying every personal credential onto a build box. The
    # GNOME desktop role would otherwise default this to true.
    age.load-owner-secrets = false;

    bootloader.systemd-boot.enable = true;
    bootloader.grub.enable = false;

    # testbench is btrfs-only; opt out of the ZFS userland that the
    # smind module defaults to (autoScrub timer, autoSnapshot, zed, …).
    zfs.enable = false;

    isDesktop = true;
    home-manager.enable = true;

    net.mode = "systemd-networkd";
    net.main-interface = "enp34s0";
    net.main-macaddr = "d8:43:ae:67:a4:ba";
    net.bridge.enable = false;
    containers.docker.enable = true;

    # SSH unlock of the LUKS root in initrd — see boot.initrd.network.ssh
    # above for the host key.
    initrd-unlock.enable = true;
    initrd-unlock.interface = "enp34s0";
    initrd-unlock.macaddr = "d8:43:ae:67:a4:ba";
  };

  age.rekey.hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO1MGoT5LiRKdzBcPoWAllHtO870RxojjI7RW2HVPV8W";

  services.xserver.videoDrivers = [ "amdgpu" ];

  services.openssh.enable = true;

  # Hostname is set automatically by the flake to the host name (testbench)
  networking.hostName = cfg-meta.hostname;
  networking.hostId = "4e2b1a3d"; # Randomly generated hex ID

  users = {
    users.root.initialPassword = "nixos";

    users.pavel = {
      isNormalUser = true;
      home = "/home/pavel";
      extraGroups = [
        "wheel"
        "audio"
        "video"
        "render"
        "networkmanager"
        "plugdev"
        "input"
        "ssh-users"
      ];
      openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel;
    };

    users.root = {
      openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel;
    };
  };

}
