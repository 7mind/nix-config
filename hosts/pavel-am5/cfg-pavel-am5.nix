{ config, cfg-meta, lib, pkgs, cfg-const, import_if_exists, cfg-flakes, ... }:

let
  llamaCppRocm = (pkgs.llama-cpp.override {
    rocmSupport = true;
    rocmGpuTargets = [ "gfx1100" ];
  }).overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./llama-cpp-json-schema-regex-shorthand.patch ];
  });
  llamaServer = lib.getExe' llamaCppRocm "llama-server";
  llamaSwap = pkgs.llama-swap.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./llama-swap-ttl-from-ready.patch ];
  });
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  nixpkgs.config.permittedInsecurePackages = [
    "python3.13-ecdsa-0.19.1"
  ];

  # Onboard MediaTek MT7927 (Filogic 380) WiFi 7 + BT — out-of-tree driver +
  # firmware until mainline support lands. See modules/nixos/mt7927-wifi.nix.
  smind.hw.mt7927.enable = true;

  nix = {
    settings = {
      max-jobs = 2;
      cores = 12;
      allowed-users = [ "root" "pavel" ];
      trusted-users = [ "root" "pavel" ];
    };
  };

  environment.systemPackages = [ llamaCppRocm ];

  virtualisation.vmware.host.enable = true;

  # VMware hardcodes paths to /usr/bin for various utilities
  systemd.tmpfiles.rules = [
    "L+ /usr/bin/vmware-ping - - - - ${config.virtualisation.vmware.host.package}/bin/vmware-ping"
    "L+ /usr/bin/vmnet-bridge - - - - ${config.virtualisation.vmware.host.package}/bin/vmnet-bridge"
    "L+ /usr/bin/vmnet-netifup - - - - ${config.virtualisation.vmware.host.package}/bin/vmnet-netifup"
    "L+ /usr/bin/vmnet-natd - - - - ${config.virtualisation.vmware.host.package}/bin/vmnet-natd"
    "L+ /usr/bin/vmnet-dhcpd - - - - ${config.virtualisation.vmware.host.package}/bin/vmnet-dhcpd"
  ];


  services = {
    llama-swap = {
      enable = true;
      package = llamaSwap;
      listenAddress = "0.0.0.0";
      port = 11435;
      openFirewall = true;

      settings =
        let
          proxy = "http://127.0.0.1:\${PORT}";
          # Shared llama-server flags. Abliterated sibling is the same
          # Qwen3.8-27B recipe (qwen35, 866 tensors, nextn_predict_layers=1)
          # so MTP / KV / ctx stay identical; only the HF GGUF changes.
          mkCmd = hfArgs:
            lib.escapeShellArgs (
              [
                llamaServer
                "--host"
                "127.0.0.1"
                "--port"
                "\${PORT}"
              ] ++ hfArgs ++ [
                "--no-mmproj"
                "-dev"
                "ROCm0"
                "-ngl"
                "99"
                "-fa"
                "on"
                "-ctk"
                "q8_0"
                "-ctv"
                "q8_0"
                "--spec-type"
                "draft-mtp"
                "--spec-draft-n-max"
                "3"
                "-ctkd"
                "q8_0"
                "-ctvd"
                "q8_0"
                "--threads"
                "12"
                "-c"
                "262144"
              ]
            );
        in
        {
          # 600s is tight for a cold 29 GB HF fetch (abliterated Q8_0).
          healthCheckTimeout = 1800;
          globalTTL = 900;

          models."qwen3.8-27b-q8" = {
            cmd = mkCmd [ "-hf" "bartowski/Qwen3.8-27B-GGUF:Q8_0" ];
            inherit proxy;
          };
          # huihui Q8_0, not Q8_0_L (38.8 GB). --hf-file pins the filename
          # because `:Q8_0` also matches Q8_0_L.
          models."qwen3.8-27b-q8-abliterated" = {
            cmd = mkCmd [
              "-hf"
              "huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF"
              "--hf-file"
              "Huihui-Qwen3.8-27B-abliterated-Q8_0.gguf"
            ];
            inherit proxy;
          };
        };
    };

    ollama.enable = lib.mkForce false;
    ollama.loadModels = lib.mkForce [ ];
    zfs.autoSnapshot.monthly = 6;

    samba = {
      # add user: sudo smbpasswd -a pavel
      # change password: sudo smbpasswd -U pavel
      # connect: smbclient //pavel-am5/Home
      enable = true;
      openFirewall = true;


      settings = {
        global = {
          security = "user";
          "workgroup" = "AD";
          "guest account" = "nobody";
          "map to guest" = "bad user";
        };

        Home = {
          path = "/home/pavel";
          "vfs objects" = "streams_xattr";
          "public" = "no";
          "browseable" = "yes";
          "writeable" = "yes";
          "printable" = "no";
          "guest ok" = "no";
          "read list" = "pavel";
          "write list" = "pavel";
          "force group" = "users";
          "comment" = "Home directory";
        };
      };
    };

    samba-wsdd = {
      enable = true;
      openFirewall = true;
    };
  };

  systemd.services = {
    llama-swap.environment = {
      HIP_VISIBLE_DEVICES = "0";
      ROCR_VISIBLE_DEVICES = "0";
    };
    llama-swap.serviceConfig.SupplementaryGroups = [ "render" ];
    ollama-custom-models.enable = false;
  };

  systemd.network = {
    links = {
      "10-eth-tmp.link" = {
        matchConfig.PermanentMACAddress = "a0:ad:9f:1e:c6:59";
        linkConfig.Name = "eth-tmp";
      };
    };

    networks = {
      "20-eth-tmp" = {
        name = "eth-tmp";
        DHCP = "yes";

        linkConfig = {
          RequiredForOnline = "no";
        };

        networkConfig = {
          IPv6PrivacyExtensions = "no";
          DHCPPrefixDelegation = "yes";
          IPv6AcceptRA = "yes";
          LinkLocalAddressing = "yes";
        };

        dhcpV4Config = {
          SendHostname = true;
          Hostname = "pavel-am5-2.home.7mind.io";
          UseDomains = true;
        };

        dhcpV6Config = {
          SendHostname = true;
          Hostname = "pavel-am5-2-ipv6.home.7mind.io";
          UseDomains = true;
        };
      };
    };

  };

  programs.winbox = {
    enable = true;
    package = pkgs.winbox-quirk;
  };

  smind = {
    roles.desktop.generic-gnome = true;
    desktop.gnome.gdm.monitors-xml = ./monitors.xml;
    desktop.gnome.switch-input-source-keybinding = [ "<Ctrl><Alt><Super>space" ];

    keyboard.super-remap.kanata.keyboards.default.kanata-switcher.enable = true;

    dev.wireshark.users = [ "pavel" "test" ];
    dev.arduino = {
      ide.enable = true;
      users = [ "pavel" ];
    };

    locale.ie.enable = true;

    security.sudo.wheel-permissive-rules = true;
    security.sudo.wheel-passwordless = true;
    security.keyring.tpmUnlock.enable = true;

    auto-login.enable = true;
    auto-login.user = "pavel";

    zfs.email.enable = true;
    host.email.to = "team@7mind.io";
    host.email.sender = "${config.networking.hostName}@home.7mind.io";

    initrd-unlock.enable = true;
    initrd-unlock.macaddr = "d0:94:66:55:aa:ab";
    # bridge-slave auto-detected from net.main-interface when net.mode is systemd-networkd

    net.main-interface = "eth-main";

    net.main-macaddr = "a0:ad:9f:1c:9e:98"; # marvel AQC113, 10g

    net.main-bridge-macaddr = "d0:94:66:55:aa:11";
    net.tailscale.enable = true;

    ssh.mode = "safe";

    hw.uhk-keyboard.enable = true;
    hw.trezor.enable = true;
    hw.ledger.enable = true;
    hw.bluetooth.enable = true;

    hw.prusa-3d-printing = {
      enable = true;
      users = [ "pavel" ];
    };

    sdr.enable = true;

    isDesktop = true;
    hw.cpu.isAmd = true;
    hw.amd.gpu.enable = true;

    bootloader.systemd-boot.enable = false;
    bootloader.lanzaboote.enable = true;

    llm.enable = true;
    llm.ollama.package = pkgs.ollama-vulkan;
    llm.ollama.customModels = [ ];
    containers.docker.enable = true;
    infra.nix-build.enable = true;

    iperf.enable = true;
    iperf.protected.server.enable = false;
    iperf.protected.client.enable = true;

    desktop.cosmic.enable = true;

    gaming.steam.enable = true;

    desktop.plymouth.enable = true;
  };

  networking.hostId = "8a9c7614";
  networking.hostName = cfg-meta.hostname;
  networking.useDHCP = false;
  networking.firewall = {
    allowedTCPPorts = [ 4001 50000 ];
    allowedUDPPorts = [ 50000 ];
    allowedTCPPortRanges = [
      {
        from = 8000;
        to = 9000;
      }
    ];
    trustedInterfaces = [ "vmnet*" ];
  };


  boot.initrd = {
    kernelModules = [ "atlantic" "igc" ];

    network = {
      ssh = {
        # `ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key`
        hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
        authorizedKeys = cfg-const.ssh-keys-pavel;
      };
    };
  };


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
      linger = true;
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
        "tss"
      ];
      openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel;
    };

    users.test = {
      isNormalUser = true;
      home = "/home/test";
      initialPassword = "test";
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
      ];
    };

  };

  home-manager.users.pavel = import ./home-pavel.nix;
  home-manager.users.root = import ./home-root.nix;
}
