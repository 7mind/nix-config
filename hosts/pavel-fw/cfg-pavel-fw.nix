{ config, cfg-meta, lib, pkgs, cfg-const, import_if_exists, import_if_exists_or, cfg-flakes, ... }:

let
  luksDevice = "/dev/disk/by-uuid/ebeec38b-52cd-4113-8d91-84e71df293af";
in
{
  imports =
    [
      ./hardware-configuration.nix
      (import_if_exists_or "${cfg-meta.paths.secrets}/pavel/age-rekey.nix" (import "${cfg-meta.paths.modules}/age-dummy.nix"))
      (import_if_exists "${cfg-meta.paths.secrets}/pavel/age-secrets.nix")
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

  # Use latest kernel with VPE fix patch for Strix Point suspend/resume
  # Override the default from kernel-settings module (6.17) - Strix Point needs latest
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages_latest;

  # Patch VPE DPM0 check to include Strix Point (6.1.0) - fixes suspend/resume hangs
  # Upstream only has Strix Halo (6.1.1) with firmware check that doesn't work for Strix Point
  # See: https://gitlab.freedesktop.org/drm/amd/-/issues/XXXXX
  boot.kernelPatches = [{
    name = "amdgpu-vpe-strix-point-dpm0-fix";
    patch = pkgs.writeText "vpe-strix-point.patch" ''
      --- a/drivers/gpu/drm/amd/amdgpu/amdgpu_vpe.c
      +++ b/drivers/gpu/drm/amd/amdgpu/amdgpu_vpe.c
      @@ -325,6 +325,8 @@ static bool vpe_need_dpm0_at_power_down(struct amdgpu_device *adev)
       {
       	switch (amdgpu_ip_version(adev, VPE_HWIP, 0)) {
      +	case IP_VERSION(6, 1, 0):
      +		return true; /* Strix Point needs DPM0 check regardless of PMFW version */
       	case IP_VERSION(6, 1, 1):
       		return adev->pm.fw_version < 0x0a640500;
       	default:
    '';
  }];

  boot.kernelParams = [
    "quiet"
    "splash"
    # AMD GPU workarounds for Strix Point
    "amdgpu.abmlevel=0" # Disable adaptive backlight
    # Prevent simpledrm from taking over framebuffer before amdgpu loads (for Plymouth)
    "initcall_blacklist=simpledrm_platform_driver_init"
  ];

  # Use systemd in initrd for proper LUKS + LVM + hibernate resume sequencing
  boot.initrd.systemd.enable = true;

  # Load AMD GPU early for Plymouth (NVIDIA driver isn't signed for SecureBoot)
  boot.initrd.kernelModules = [ "amdgpu" ];
  hardware.amdgpu.initrd.enable = true;

  # Graphical boot splash
  boot.plymouth.enable = true;
  boot.plymouth.theme = "bgrt"; # Framework logo with spinner
  boot.consoleLogLevel = 3;
  boot.initrd.verbose = false;

  # LUKS encryption with TPM2 auto-unlock
  # Re-enroll after UEFI/TPM changes: tpm-enroll-luks
  boot.initrd.luks.devices."enc" = {
    device = luksDevice;
    preLVM = true;
    crypttabExtraOpts = [ "tpm2-device=auto" ];
  };

  environment.systemPackages = [
    pkgs.fw-ectool # Framework EC tool for fan control, battery charge limit, etc.
    pkgs.framework-tool # Swiss army knife CLI for Framework laptops
    pkgs.framework-tool-tui # TUI for controlling Framework hardware
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

  # Framework-specific services
  hardware.sensor.iio.enable = true; # ALS sensor for wluma

  # Framework laptop kernel module for battery charge limit and LED control
  boot.extraModulePackages = [ config.boot.kernelPackages.framework-laptop-kmod ];
  boot.kernelModules = [ "framework_laptop" ];

  # Allow wluma to claim sensors from iio-sensor-proxy
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "net.hadess.SensorProxy.claim-sensor") {
        return polkit.Result.YES;
      }
    });
  '';

  services.power-profiles-daemon.enable = true;
  smind.power-management.auto-profile.enable = true;
  smind.power-management.auto-profile.onAC = "performance";

  # QMK keyboard firmware support (Framework 16 uses QMK)
  # Use https://keyboard.frame.work/ for configuration
  hardware.keyboard.qmk.enable = true;

  # Framework keyboard udev rules for web configurator access
  services.udev.extraRules = ''
    # Framework Laptop 16 Keyboard Module - ANSI (32ac:0012)
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0012", MODE="0660", GROUP="users", TAG+="uaccess"
    SUBSYSTEM=="usb", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0012", MODE="0660", GROUP="users", TAG+="uaccess"

    # Enable illuminance scan element for ALS buffer mode (Framework 16)
    ACTION=="add", SUBSYSTEM=="iio", ATTR{name}=="als", ATTR{scan_elements/in_illuminance_en}="1"
  '';

  # Workaround: Unload MT7925e WiFi before suspend/hibernate (driver doesn't support PM properly)
  powerManagement = {
    powerDownCommands = "${pkgs.kmod}/bin/modprobe -r mt7925e";
    resumeCommands = "${pkgs.kmod}/bin/modprobe mt7925e";
  };

  smind = {
    age.enable = true;
    roles.desktop.generic-gnome = true;
    isLaptop = true;

    dev.adb.users = [ "pavel" ];
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
    desktop.gnome.ambient-light-sensor.enable = false;
    desktop.gnome.framework-fan-control.enable = true;
    desktop.gnome.gdm.monitors-xml = ./monitors.xml;

    desktop.cosmic.enable = true;

    locale.ie.enable = true;

    host.email.to = "team@7mind.io";
    host.email.sender = "${config.networking.hostName}@home.7mind.io";

    security.sudo.wheel-permissive-rules = true;
    security.sudo.wheel-passwordless = true;
    security.keyring.tpmUnlock.enable = true;

    # Networking - use NetworkManager for laptop mobility
    net.enable = false; # Disable systemd-networkd based networking
    net.tailscale.enable = true;

    hw.bluetooth.enable = true;
    hw.fingerprint.enable = true;
    hw.nvidia = {
      enable = true;
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
    # hw.trezor.enable = true;
    hw.ledger.enable = true;
    containers.docker.enable = true;

    ssh.mode = "safe";

    isDesktop = true;
    hw.cpu.isAmd = true;
    hw.amd.gpu.enable = true;

    # LLM/Ollama - use Vulkan for Strix Point (RDNA 3.5)
    # Alternative: ollama-rocm with rocmOverrideGfx = "11.5.0" (gfx1150)
    llm.enable = true;
    llm.ollama.package = pkgs.ollama-vulkan;
    llm.ollama.customContextLength = 32768;

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
  };

  # Use NetworkManager for laptop (instead of systemd-networkd)
  networking.networkmanager.enable = true;

  networking.hostId = "a1b2c3d4";
  networking.hostName = cfg-meta.hostname;
  networking.useDHCP = false;

  # Firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ ];
  };

  # OpenSnitch application firewall (disabled - adds ~80 wakeups/s overhead)
  smind.net.opensnitch.enable = false;

  users = {
    users.root.initialPassword = "nixos";

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
