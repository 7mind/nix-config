{ config, cfg-meta, lib, pkgs, cfg-const, import_if_exists, cfg-flakes, ... }:

let
  luksDevice = "/dev/disk/by-uuid/ebeec38b-52cd-4113-8d91-84e71df293af";
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  nixpkgs.config.permittedInsecurePackages = [
    "python3.13-ecdsa-0.19.1" # trezor dependency, CVE-2024-23342
  ];

  nix = {
    settings = {
      max-jobs = 2;
      cores = 18;
      allowed-users = [ "root" "pavel" ];
      trusted-users = [ "root" "pavel" ];
    };
  };

  age.rekey = {
    hostPubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILVhIJvhBhZBZwwW+XNYWLRn5wL+ecMkWRYcuqmJVq1r";
  };

  # --- Framework 16 AMD (Strix Point) specific configuration ---

  boot.kernelParams = [
    #"usbcore.autosuspend=-1"
  ];

  # Use systemd in initrd for proper LUKS + LVM + hibernate resume sequencing
  boot.initrd.systemd.enable = true;

  # LUKS encryption with TPM2 auto-unlock
  # Re-enroll after UEFI/TPM changes: tpm-enroll-luks
  boot.initrd.luks.devices."enc" = {
    device = luksDevice;
    preLVM = true;
    crypttabExtraOpts = [ "tpm2-device=auto" ];
  };

  environment.systemPackages = [
    pkgs.powertop # Power consumption analysis

    (pkgs.writeShellScriptBin "tpm-enroll-luks" ''
      set -euo pipefail
      echo "LUKS TPM2 Enrollment"
      echo "===================="
      echo ""
      echo "This will re-enroll TPM2 key for LUKS device:"
      echo "  ${luksDevice}"
      echo ""
      echo "Use this after UEFI/TPM configuration changes."
      echo "You will be prompted for your LUKS recovery passphrase."
      echo ""
      sudo ${pkgs.systemd}/bin/systemd-cryptenroll \
        --wipe-slot=tpm2 \
        --tpm2-device=auto \
        --tpm2-pcrs=0+7 \
        "${luksDevice}"
      echo ""
      echo "Done! TPM auto-unlock will work on next boot."
    '')

    (pkgs.writeShellScriptBin "tpm-unenroll-luks" ''
      set -euo pipefail
      echo "LUKS TPM2 Unenrollment"
      echo "======================"
      echo ""
      echo "This will remove TPM2 auto-unlock for LUKS device:"
      echo "  ${luksDevice}"
      echo ""
      echo "You may be prompted for your LUKS recovery passphrase."
      echo ""
      read -r -p "Remove TPM2 enrollment from this LUKS device? [y/N] " REPLY
      if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
      fi
      sudo ${pkgs.systemd}/bin/systemd-cryptenroll \
        --wipe-slot=tpm2 \
        "${luksDevice}"
      echo ""
      echo "Done! TPM auto-unlock has been removed."
    '')

    pkgs.video-trimmer
  ];

  # Resume device for hibernation
  boot.resumeDevice = "/dev/vg/swap";

  boot.loader.efi.canTouchEfiVariables = true;

  boot.loader.systemd-boot.extraEntries = {
    "windows.conf" = ''
      title Windows
      efi /EFI/Microsoft/Boot/bootmgfw.efi
    '';
  };

  # WiFi card was swapped from Qualcomm WCN785x (ath12k) to MediaTek MT7925 (mt7921e)
  # Keeping disabled PCI runtime PM workaround for reference:
  # services.udev.extraRules = lib.mkAfter ''
  #   ACTION=="add|change", SUBSYSTEM=="pci", KERNEL=="0000:00:02.3", ATTR{power/control}="on"
  # '';

  smind = {
    nix.nix-impl = "determinate";
    age.enable = true;
    roles.desktop.generic-gnome = true;
    isLaptop = true;

    keyboard.super-remap.kanata.keyboards.default.kanata-switcher.enable = true;
    dev.wireshark.users = [ "pavel" ];

    power-management.enable = true;
    power-management.auto-refresh-rate = {
      enable = true;
      displays."eDP-1" = {
        gnome = {
          onAC = "2560x1600@165.000+vrr";
          onBattery = "2560x1600@60.002+vrr";
        };
        cosmic = {
          onAC = "2560x1600@165Hz";
          onBattery = "2560x1600@60Hz";
        };
      };
    };
    desktop.gnome.fractional-scaling.enable = true;
    desktop.gnome.vrr.enable = true;
    desktop.gnome.gdm.monitors-xml = ./monitors.xml;
    desktop.gnome.touchpad.disableWhileTyping = true;

    desktop.cosmic.enable = true;

    locale.ie.enable = true;

    host.email.to = "team@7mind.io";
    host.email.sender = "${config.networking.hostName}@home.7mind.io";

    security.sudo.wheel-permissive-rules = true;
    security.sudo.wheel-passwordless = true;
    security.keyring.tpmUnlock.enable = true;

    # Networking - use NetworkManager for laptop mobility
    net.mode = "networkmanager";
    net.tailscale.enable = true;

    desktop.plymouth.enable = true;
    hw.framework-laptop.enable = true;
    hw.bluetooth.enable = true;
    hw.fingerprint.enable = true;
    hw.nvidia = {
      enable = true;
      open = true; # RTX 50 series (Blackwell) requires open kernel modules
      package = config.boot.kernelPackages.nvidiaPackages.beta; # 590.x beta - may have GSP fix for mobile Blackwell
      specialisation.enable = true;
      specialisation.defaultWithGpu = true; # Default boots with NVIDIA, "no-nvidia" specialisation for AMD-only
      # PCI IDs from lspci -Dnn
      pciId = "0000:c2:00.0";
      audioPciId = "0000:c2:00.1";
      vendorDeviceId = "10de 2d58";
      audioVendorDeviceId = "10de 22eb";
      # Decimal bus IDs for PRIME (c2 hex = 194, c3 hex = 195)
      nvidiaBusId = "PCI:194:0:0";
      amdgpuBusId = "PCI:195:0:0";
    };
    hw.trezor.enable = true;
    hw.ledger.enable = true;
    hw.qmk-keyboard.enable = true;
    hw.qmk-keyboard.frameworkKeyboard = true;
    containers.docker.enable = true;

    ssh.mode = "safe";

    infra.attic-cache.enable = true;
    iperf.enable = true;

    isDesktop = true;
    hw.cpu.isAmd = true;
    hw.amd.gpu.enable = true;

    # LLM/Ollama - use Vulkan for Strix Point (RDNA 3.5)
    # Alternative: ollama-rocm with rocmOverrideGfx = "11.5.0" (gfx1150)
    llm.enable = true;
    llm.ollama.package = pkgs.ollama-vulkan;
    llm.ollama.customModels = [
    ];
    llm.ollama.customContextLength = 131072;

    gaming.steam.enable = true;

    # Virtualization
    vm.virt-manager = {
      enable = true;
      gpuPassthrough = {
        enable = true;
        vmNames = [ "win11" ];
      };
    };

    # Use lanzaboote for secure boot
    bootloader.systemd-boot.enable = false;
    bootloader.lanzaboote.enable = true;

    # Disable ZFS (using btrfs on LVM)
    zfs.enable = false;

    btrfs.snapshots = {
      enable = true;
      volumePath = "/home";
      subvolumePath = ".";
    };
  };

  # Prefer RTX 5060 first while still allowing fallback to Radeon 890M.
  services.ollama.environmentVariables.GGML_VK_VISIBLE_DEVICES = lib.mkForce "1,0";

  systemd.services.ollama.serviceConfig.MemoryDenyWriteExecute = lib.mkForce false;

  networking.hostId = "a1b2c3d4";
  networking.hostName = cfg-meta.hostname;
  networking.useDHCP = false;

  # Firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ ];
  };

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
        "cdrom"
        "disk"
        "uinput"
        "plugdev"
        "networkmanager"
        "ssh-users"
        "kvm"
        "libvirtd"
        "qemu"
        "qemu-libvirtd"
        "podman"
        "ollama"
        "tss"
      ];
      openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel;
    };
  };

  home-manager.users.pavel = import ./home-pavel.nix;
  home-manager.users.root = import ./home-root.nix;

}
