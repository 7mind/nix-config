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

  # Test: kernel 6.12 LTS to rule out amdgpu suspend_noirq regression in 6.17+
  # https://community.frame.work/t/attn-critical-bugs-in-amdgpu-driver-included-with-kernel-6-18-x-6-19-x/79221
  # Previous: linux_6_18 (needed for NVIDIA open 590 compat, but causes s2idle crash)
  boot.kernelPackages = lib.mkForce pkgs.linuxKernel.packages.linux_6_12;

  boot.kernelParams = [
    "quiet"
    "splash"
    #"usbcore.autosuspend=-1"
    # AMD GPU workarounds for Strix Point
    "amdgpu.abmlevel=0" # Disable adaptive backlight
    # Prevent simpledrm from taking over framebuffer before amdgpu loads (for Plymouth)
    "initcall_blacklist=simpledrm_platform_driver_init"
    # s2idle crash workarounds for Strix Point on kernel 6.18.x
    # https://community.frame.work/t/attn-critical-bugs-in-amdgpu-driver-included-with-kernel-6-18-x-6-19-x/79221
    "amdgpu.cwsr_enable=0" # Disable broken CWSR that causes MES ring saturation and hard freezes
    "amdgpu.dcdebugmask=0x610" # Disable PSR + PSR-SU + PSR2 (0x10|0x200|0x400) — all cause s2idle failures on Strix Point
    "amd_iommu=fullflush" # Prevent IOMMU-related suspend failures with NVMe
    # Ignore NVIDIA dGPU GPIO interrupt that prevents s2idle entry on AMD+NVIDIA hybrid laptops
    # https://forums.developer.nvidia.com/t/590-6-18-suspend-immediately-interrupted-by-dgpu-on-amd-nvidia-laptops/357805
    "gpiolib_acpi.ignore_interrupt=AMDI0030:00@16"
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

  # Power management via TuneD (replaces power-profiles-daemon)
  # Defaults: latency-performance on AC, powersave on battery

  # Framework 16 udev rules
  services.udev.extraRules = lib.mkAfter ''
    # Enable illuminance scan element for ALS buffer mode
    ACTION=="add", SUBSYSTEM=="iio", ATTR{name}=="als", ATTR{scan_elements/in_illuminance_en}="1"
    # Disable PCI runtime PM for WiFi parent bridge to prevent ath12k firmware crash
    # The bridge (00:02.3) routes to the Qualcomm WCN785x WiFi (c0:00.0)
    # Runtime PM on the bridge causes ath12k to crash - targeting device directly doesn't work
    ACTION=="add|change", SUBSYSTEM=="pci", KERNEL=="0000:00:02.3", ATTR{power/control}="on"
  '';

  # Workaround: Unload MT7925e WiFi before suspend/hibernate (driver doesn't support PM properly)
  # systemd.services.mt7925e-suspend = {
  #   description = "Unload MT7925e WiFi before suspend";
  #   before = [ "sleep.target" ];
  #   wantedBy = [ "sleep.target" ];
  #   unitConfig.StopWhenUnneeded = true;
  #   serviceConfig = {
  #     Type = "oneshot";
  #     RemainAfterExit = true;
  #     ExecStart = "${pkgs.kmod}/bin/modprobe -r mt7925e";
  #     ExecStop = pkgs.writeShellScript "mt7925e-resume" ''
  #       set -euo pipefail

  #       # Wait for PCIe device to be ready
  #       sleep 1

  #       # Load module with retry
  #       for i in 1 2 3; do
  #         if ${pkgs.kmod}/bin/modprobe mt7925e 2>/dev/null; then
  #           echo "mt7925e loaded on attempt $i"
  #           break
  #         fi
  #         echo "modprobe attempt $i failed, retrying..."
  #         sleep 1
  #       done

  #       # Wait for interface to appear
  #       for i in $(seq 1 10); do
  #         if ${pkgs.iproute2}/bin/ip link show wlan0 &>/dev/null; then
  #           echo "wlan0 interface is up"
  #           break
  #         fi
  #         sleep 0.5
  #       done

  #       # Give NetworkManager a kick if interface appeared
  #       if ${pkgs.iproute2}/bin/ip link show wlan0 &>/dev/null; then
  #         sleep 1
  #         ${pkgs.networkmanager}/bin/nmcli device set wlan0 managed yes 2>/dev/null || true
  #         ${pkgs.networkmanager}/bin/nmcli device reapply wlan0 2>/dev/null || true
  #       else
  #         echo "WARNING: wlan0 did not appear after resume"
  #       fi
  #     '';
  #   };
  # };

  # Unload ath12k before suspend — WCN7850 firmware fails to enter power save cleanly,
  # causing s2idle entry failures (constant "failed to pull fw stats: -71" EPROTO errors)
  systemd.services.ath12k-suspend = {
    description = "Unload ath12k WiFi before suspend";
    before = [ "sleep.target" ];
    wantedBy = [ "sleep.target" ];
    unitConfig.StopWhenUnneeded = true;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "ath12k-unload" ''
        set -euo pipefail
        if lsmod | grep -wq ath12k; then
          logger -p user.info "Unloading ath12k before suspend"
          ${pkgs.kmod}/bin/modprobe -r ath12k_pci ath12k 2>/dev/null || true
        fi
      '';
      ExecStop = pkgs.writeShellScript "ath12k-reload" ''
        set -euo pipefail
        if ! lsmod | grep -wq ath12k; then
          logger -p user.info "Reloading ath12k after resume"
          sleep 1
          ${pkgs.kmod}/bin/modprobe ath12k_pci 2>/dev/null || true
          sleep 3
          ${pkgs.networkmanager}/bin/nmcli device set wlan0 managed yes 2>/dev/null || true
        fi
      '';
    };
  };

  # Disable Thunderbolt NHI wakeup sources — they generate spurious interrupts
  # that prevent s0ix entry on AMD platforms
  systemd.services.disable-thunderbolt-wakeup = {
    description = "Disable Thunderbolt NHI wakeup for s2idle";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "disable-nhi-wakeup" ''
        set -euo pipefail
        for dev in NHI0 NHI1; do
          if grep -q "$dev.*enabled" /proc/acpi/wakeup; then
            echo "$dev" > /proc/acpi/wakeup
            logger -p user.info "Disabled ACPI wakeup for $dev"
          fi
        done
      '';
    };
  };

  smind = {
    nix.nix-impl = "determinate";
    age.enable = true;
    roles.desktop.generic-gnome = true;
    isLaptop = true;
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
    desktop.gnome.framework-fan-control.enable = false;
    desktop.gnome.gdm.monitors-xml = ./monitors.xml;
    desktop.gnome.touchpad.disableWhileTyping = false;

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

    iperf.enable = true;

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
