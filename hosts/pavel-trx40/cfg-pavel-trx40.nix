{ config, cfg-meta, lib, pkgs, cfg-const, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  nix = {
    settings = {
      # Threadripper 3970x: 32 cores / 64 threads. Leave a few jobs in
      # parallel to keep the box responsive while compiling.
      max-jobs = 2;
      cores = 48;
      allowed-users = [ "root" "pavel" ];
      trusted-users = [ "root" "pavel" ];
    };
  };

  # aarch64 emulation so this box can build raspi/oracle-cloud closures
  # locally instead of paying for remote builders.
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  smind = {
    home-manager.enable = true;

    locale.ie.enable = true;

    security.sudo.wheel-permissive-rules = true;
    security.sudo.wheel-passwordless = true;

    # Email/msmtp deferred until after the first `agenix rekey -a`
    # pass: enabling it pulls in the msmtp-password secret which has
    # to be rekeyed to this host's pubkey first. Flip both options
    # back on (along with `smind.zfs.email.enable = true`) once the
    # rekeyed file lands under `private/secrets/rekeyed/pavel-trx40/`.
    host.email.enable = false;

    # ZFS initrd unlock over SSH. The Realtek on-board NIC stays put
    # under its permanent MAC and is enslaved to a synthetic bridge in
    # both the initrd and the booted system so the rest of the
    # networking pipeline (containers, VLANs, …) has a stable handle.
    zfs.initrd-unlock.enable = true;
    zfs.initrd-unlock.macaddr = "00:e0:4c:75:00:9e";
    # bridge-slave auto-detected from net.main-interface

    net.mode = "systemd-networkd";
    net.main-interface = "eth-main";
    net.main-macaddr = "00:e0:4c:75:00:9c"; # on-board Realtek NIC
    net.main-bridge-macaddr = "00:e0:4c:75:00:9d";

    net.tailscale.enable = true;

    ssh.mode = "safe";

    isDesktop = false;
    hw.cpu.isAmd = true;

    # AMD Radeon 6900XT — amdgpu kernel driver, ROCm compute stack,
    # OpenCL via rocmPackages.clr. Enabling this turns on
    # `nixpkgs.config.rocmSupport` globally (see modules/nixos/rocm.nix).
    hw.amd.gpu.enable = true;

    # NVIDIA RTX 3080 — CUDA compute. PRIME offload between the AMD
    # 6900XT (primary) and the 3080 (offload target), matching how this
    # box was set up under the old config. Bus IDs are preserved from
    # `debug/nixos-infra/hosts/ws/pavel-nix/cfg-pavel-nix.nix` — verify
    # with `lspci -D | grep -i "vga\|3d"` after the takeover and
    # adjust if the slot wiring changed.
    hw.nvidia = {
      enable = true;
      # RTX 3080 (Ampere): proprietary driver is the better-tested
      # path; flip to `open = true` once the open modules are validated.
      open = false;
      amdgpuBusId = "PCI:23:0:0";
      nvidiaBusId = "PCI:02:0:0";
    };

    # ESP32 / Arduino USB-TTY flashing. No IDE on a headless build
    # machine; the module's value is the CH340 udev rule and the
    # `dialout` group on `pavel`. CP210x, FTDI, and CDC-ACM are
    # already handled by upstream nixpkgs rules.
    dev.arduino.users = [ "pavel" ];

    bootloader.systemd-boot.enable = true;
    bootloader.lanzaboote.enable = false;

    # Build/work machine: keep nix-build infrastructure on, expose LLM
    # tooling for Claude workflows.
    infra.nix-build.enable = true;
    # Trust the local nix signing key so closures pushed from other
    # hosts (e.g. `./setup -s` from vm) are accepted, and substitute
    # from the home attic cache. `push.enable` deferred until after the
    # first `agenix rekey -a` pass (needs attic-admin-token and
    # nix-signing-key rekeyed to this host's pubkey).
    infra.attic-cache.enable = true;
    llm.enable = true;
  };

  # CUDA-enabled package variants. allowUnfree is required by the
  # NVIDIA driver and by cuDNN; rocmSupport is turned on by the AMD
  # module above. Enabling both simultaneously means ML packages that
  # opt into either backend will rebuild from source.
  nixpkgs.config = {
    allowUnfree = true;
    # cudaSupport = true;
  };

  # hostId preserved from the prior install on this machine — required
  # for ZFS to import the existing zroot pool without `-f`.
  networking.hostId = "152c7c72";
  networking.hostName = cfg-meta.hostname;
  networking.domain = "home.7mind.io";
  networking.useDHCP = false;

  # initrd SSH host key: provisioned out-of-band on the running host with
  #   ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key
  # mirrors how pavel-am5 handles it (no agenix dependency, so this
  # config builds before the box has been enrolled).
  boot.initrd.network.ssh = {
    hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
    authorizedKeys = cfg-const.ssh-keys-pavel;
  };

  users = {
    users.root = {
      openssh.authorizedKeys.keys =
        cfg-const.ssh-keys-pavel ++
        cfg-const.ssh-keys-nix-builder;
    };

    users.pavel = {
      isNormalUser = true;
      home = "/home/pavel";
      extraGroups = [
        "wheel"
        "audio"
        "video"
        "render"
        "cdrom"
        "disk"
        "networkmanager"
        "plugdev"
        "input"
        "libvirtd"
        "qemu"
        "qemu-libvirtd"
        "kvm"
        "uinput"
        "ssh-users"
        "podman"
        "ollama"
      ];
      openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel;
    };
  };

  home-manager.users.pavel = import ./home-pavel.nix;
  home-manager.users.root = import ./home-root.nix;

  environment.systemPackages = with pkgs; [ ];
}
