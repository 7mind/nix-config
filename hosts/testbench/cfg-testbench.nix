{ config, cfg-meta, lib, pkgs, cfg-const, import_if_exists, import_if_exists_or, cfg-flakes, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      (import_if_exists_or "${cfg-meta.paths.secrets}/pavel/age-rekey.nix" (import "${cfg-meta.paths.modules}/age-dummy.nix"))
    ];

  nix = {
    settings = {
      max-jobs = 2;
      cores = 6;
      allowed-users = [ "root" "pavel" ];
      trusted-users = [ "root" "pavel" ];
    };
  };

  systemd.network = {
    networks = {
      "20-${config.smind.net.main-bridge}" = {
        ipv6AcceptRAConfig = {
          Token = "::0025";
        };
      };
    };
  };

  smind = {
    roles.desktop.generic-gnome = false;
    home-manager.enable = true;

    locale.ie.enable = true;

    security.sudo.wheel-permissive-rules = true;
    security.sudo.wheel-passwordless = true;

    zfs.email.enable = true;
    host.email.to = "team@7mind.io";
    host.email.sender = "${config.networking.hostName}@home.7mind.io";

    net.main-interface = "eth-main";

    net.enable = true;
    net.main-macaddr = "A8:A1:59:BC:73:CD";
    net.main-bridge-macaddr = "A8:A1:59:BC:73:CC";

    net.tailscale.enable = true;

    ssh.mode = "safe";

    isDesktop = false;
    hw.cpu.isAmd = true;
    hw.amd.gpu.enable = true;

    bootloader.systemd-boot.enable = true;
    bootloader.lanzaboote.enable = false;

    llm.enable = true;
    infra.nix-build.enable = true;
  };


  networking.hostId = "67ca4589";
  networking.hostName = cfg-meta.hostname;
  networking.domain = "home.7mind.io";
  networking.useDHCP = false;

  boot.loader = {
    systemd-boot = {
      windows = {
        "11".efiDeviceHandle = "HD1b";
      };
    };
  };

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

    users.root = {
      openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel;
    };
  };

  home-manager.users.pavel = import ./home-pavel.nix;
  home-manager.users.root = import ./home-root.nix;

  environment.systemPackages = with pkgs; [

  ];

  services.ollama = {
    rocmOverrideGfx = "10.3.0";
    environmentVariables = { };
  };

}
