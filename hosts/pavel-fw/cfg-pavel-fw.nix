{ config, cfg-meta, lib, pkgs, cfg-const, import_if_exists, import_if_exists_or, cfg-flakes, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      # Skip age-rekey for now until secrets are set up for this host
      "${cfg-meta.paths.modules}/age-dummy.nix"
    ];

  nix = {
    settings = {
      max-jobs = 2;
      cores = 8;
      allowed-users = [ "root" "pavel" ];
      trusted-users = [ "root" "pavel" ];
    };
  };

  # --- Framework 16 AMD (Strix Point) specific configuration ---

  # Use latest kernel with VPE fix patch for Strix Point suspend/resume
  # Override the default from kernel-settings module (6.17) - Strix Point needs latest
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages_latest;

  # Patch VPE idle timeout to fix suspend/resume on Strix Point
  # See: https://www.mail-archive.com/amd-gfx@lists.freedesktop.org/msg127724.html
  boot.kernelPatches = [{
    name = "amdgpu-vpe-idle-timeout-fix";
    patch = pkgs.writeText "vpe-timeout.patch" ''
--- a/drivers/gpu/drm/amd/amdgpu/amdgpu_vpe.c
+++ b/drivers/gpu/drm/amd/amdgpu/amdgpu_vpe.c
@@ -37,7 +37,7 @@

 /* 1 second timeout */
-#define VPE_IDLE_TIMEOUT	msecs_to_jiffies(1000)
+#define VPE_IDLE_TIMEOUT	msecs_to_jiffies(2000)

 #define VPE_MAX_DPM_LEVEL			4
 #define FIXED1_8_BITS_PER_FRACTIONAL_PART	8
'';
  }];

  boot.kernelParams = [
    "quiet"
    "splash"
    # AMD GPU resume workarounds for Strix Point
    "amdgpu.sg_display=0"      # Disable scatter-gather display (helps resume)
    "amdgpu.abmlevel=0"        # Disable adaptive backlight (reduces resume complexity)
  ];

  # Use systemd in initrd for proper LUKS + LVM + hibernate resume sequencing
  boot.initrd.systemd.enable = true;

  # Graphical boot splash
  boot.plymouth.enable = true;
  boot.plymouth.theme = "bgrt"; # Framework logo with spinner
  boot.consoleLogLevel = 3;
  boot.initrd.verbose = false;

  # LUKS encryption with TPM2 auto-unlock
  boot.initrd.luks.devices."enc" = {
    device = "/dev/disk/by-uuid/ebeec38b-52cd-4113-8d91-84e71df293af";
    preLVM = true;
    crypttabExtraOpts = [ "tpm2-device=auto" ];
  };

  # Resume device for hibernation
  boot.resumeDevice = "/dev/vg/swap";

  boot.loader.efi.canTouchEfiVariables = true;

  # Framework-specific services
  services.power-profiles-daemon.enable = true;

  # QMK keyboard firmware support (Framework 16 uses QMK)
  # Use https://keyboard.frame.work/ for configuration
  hardware.keyboard.qmk.enable = true;

  # Framework keyboard udev rules for web configurator access
  services.udev.extraRules = ''
    # Framework Laptop 16 Keyboard Module - ANSI (32ac:0012)
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0012", MODE="0660", GROUP="users", TAG+="uaccess"
    SUBSYSTEM=="usb", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0012", MODE="0660", GROUP="users", TAG+="uaccess"
  '';

  # Workaround: Unload MT7925e WiFi before suspend/hibernate (driver doesn't support PM properly)
  powerManagement = {
    powerDownCommands = "${pkgs.kmod}/bin/modprobe -r mt7925e";
    resumeCommands = "${pkgs.kmod}/bin/modprobe mt7925e";
  };

  # Disable age secrets until they are set up for this host
  smind.age.enable = false;

  smind = {
    roles.desktop.generic-gnome = true;
    isLaptop = true;
    desktop.gnome.fractional-scaling.enable = false;

    # Disable keyd (using kanata instead)
    keyboard.super-remap.enable = false;

    locale.ie.enable = true;

    host.email.to = "team@7mind.io";
    host.email.sender = "${config.networking.hostName}@home.7mind.io";

    security.sudo.wheel-permissive-rules = true;
    security.sudo.wheel-passwordless = true;
    security.keyring.tpmUnlock.enable = true;

    # Networking - use NetworkManager for laptop mobility
    net.enable = false; # Disable systemd-networkd based networking

    hw.bluetooth.enable = true;
    hw.fingerprint.enable = true;
    containers.docker.enable = true;

    ssh.mode = "safe";

    isDesktop = true;
    hw.cpu.isAmd = true;
    hw.amd.gpu.enable = true;

    # Use lanzaboote for secure boot
    bootloader.systemd-boot.enable = false;
    bootloader.lanzaboote.enable = true;

    # Disable ZFS (using btrfs on LVM)
    zfs.enable = false;
  };

  # Kanata keyboard remapper (Mac-style shortcuts)
  services.kanata = {
    enable = true;
    keyboards.default = {
      devices = [ ];
      extraDefCfg = ''
        process-unmapped-keys yes
      '';
      config = ''
        ;; Only remap Caps Lock
        (defsrc caps)

        (defalias
          ;; Caps Lock: Hyper (Ctrl+Alt+Super+Space), Shift+Caps = real Caps Lock
          hyp (fork
                (multi lctl lalt lmet spc)
                caps
                (lsft rsft))
        )

        (deflayer base @hyp)

        ;; Mac-style: Super+Key → Ctrl+Key (only for specific keys)
        ;; Super+Tab, Super+Q, etc. are NOT remapped (handled by GNOME)
        (defoverrides
          ;; Text editing
          (lmet a) (lctl a)    ;; Select all
          (lmet c) (lctl c)    ;; Copy
          (lmet v) (lctl v)    ;; Paste
          (lmet x) (lctl x)    ;; Cut
          (lmet z) (lctl z)    ;; Undo
          ;; File operations
          (lmet s) (lctl s)    ;; Save
          (lmet o) (lctl o)    ;; Open
          (lmet p) (lctl p)    ;; Print / Command palette
          ;; Navigation
          (lmet f) (lctl f)    ;; Find
          (lmet l) (lctl l)    ;; Address bar / Go to line
          (lmet r) (lctl r)    ;; Refresh
          ;; Window/tab management
          (lmet t) (lctl t)    ;; New tab
          (lmet n) (lctl n)    ;; New window
          (lmet w) (lctl w)    ;; Close tab/window
          ;; Super+Shift combinations
          (lmet lsft z) (lctl lsft z)  ;; Redo
          (lmet lsft f) (lctl lsft f)  ;; Find in files
          (lmet lsft t) (lctl lsft t)  ;; Reopen closed tab
          (lmet lsft n) (lctl lsft n)  ;; New incognito/private window
          (lmet lsft p) (lctl lsft p)  ;; Command palette (VS Code)
        )
      '';
    };
  };

  # Use NetworkManager for laptop (instead of systemd-networkd)
  networking.networkmanager.enable = true;

  networking.hostId = "a1b2c3d4"; # Required for ZFS compatibility checks
  networking.hostName = cfg-meta.hostname;
  networking.useDHCP = false;

  time.timeZone = "Europe/Dublin";

  users = {
    users.root.password = "nixos";

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
        "adbusers"
        "corectrl"
        "wireshark"
        "tss"
      ];
      openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel;
    };
  };

  home-manager.users.pavel = import ./home-pavel.nix;
  home-manager.users.root = import ./home-root.nix;
}
