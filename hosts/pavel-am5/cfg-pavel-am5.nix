{ config, cfg-meta, lib, pkgs, cfg-const, import_if_exists, import_if_exists_or, cfg-flakes, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      (import_if_exists_or "${cfg-meta.paths.secrets}/pavel/age-rekey.nix" (import "${cfg-meta.paths.modules}/age-dummy.nix"))
    ];

  nixpkgs.config.permittedInsecurePackages = [
    # "fluffychat-linux-1.23.0"
    # "olm-3.2.16"
    "python3.13-ecdsa-0.19.1"
  ];

  nix = {
    settings = {
      max-jobs = 2;
      cores = 12;
      allowed-users = [ "root" "pavel" ];
      trusted-users = [ "root" "pavel" ];
    };
  };

  services = {
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
          #"force directory mode" = "0770";
          #"force create mode" = "0660";
          "comment" = "Home directory";
        };
      };
    };

    samba-wsdd = {
      enable = true;
      openFirewall = true;
    };
  };

  systemd.network = {
    links = {
      "10-eth-tmp.link" = {
        matchConfig.PermanentMACAddress = "a0:ad:9f:1e:c6:59";
        linkConfig.Name = "eth-tmp";
      };
    };

    networks = {
      "20-${config.smind.net.main-bridge}" = {
        ipv6AcceptRAConfig = {
          Token = "::0020";
        };
      };

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
          Hostname = "${config.networking.hostName}-2.${config.networking.domain}";
          UseDomains = true;
        };

        dhcpV6Config = {
          SendHostname = true;
          Hostname = "${config.networking.hostName}-2-ipv6.${config.networking.domain}";
          UseDomains = true;
        };
      };
    };

  };

  # networkmanager does not manage ethernet on this host, so gnome connectivity check fails
  environment.sessionVariables.GIO_USE_NETWORK_MONITOR = "base";

  programs.winbox = {
    enable = true;
    package = pkgs.winbox-quirk;
  };

  smind = {
    roles.desktop.generic-gnome = true;
    desktop.gnome.gdm.monitors-xml = ./monitors.xml;

    dev.adb.users = [ "pavel" "test" ];
    dev.wireshark.users = [ "pavel" "test" ];

    locale.ie.enable = true;

    security.sudo.wheel-permissive-rules = true;
    security.sudo.wheel-passwordless = true;

    zfs.email.enable = true;
    host.email.to = "team@7mind.io";
    host.email.sender = "${config.networking.hostName}@home.7mind.io";

    zfs.initrd-unlock.enable = true;
    zfs.initrd-unlock.macaddr = "d0:94:66:55:aa:ab";

    net.main-interface = "eth-main";

    net.main-macaddr = "a0:ad:9f:1c:9e:98"; # marvel AQC113, 10g
    # net.main-macaddr = "a0:ad:9f:1e:c6:59"; # intel I226-V, 2.5g

    net.main-bridge-macaddr = "d0:94:66:55:aa:11";
    net.tailscale.enable = true;

    ssh.mode = "safe";

    hw.uhk-keyboard.enable = true;
    hw.trezor.enable = true;
    hw.ledger.enable = true;
    hw.bluetooth.enable = true;

    isDesktop = true;
    hw.cpu.isAmd = true;
    hw.amd.gpu.enable = true;

    bootloader.systemd-boot.enable = false;
    bootloader.lanzaboote.enable = true;

    llm.enable = true;
    containers.docker.enable = true;
    infra.nix-build.enable = true;

    iperf.enable = true;
    iperf.protected.server.enable = false;
    iperf.protected.client.enable = true;

    desktop.cosmic.enable = true;
    # desktop.cosmic.minimal-keybindings = true;

    audio.quirks = {
      enable = true;
      devices = [
        {
          name = "Jabra Link 390";
          vendorId = "0b0e";
          productId = "2e56";
          formFactor = "headset";
        }
      ];
    };

    audio.autoswitch = {
      enable = true;
      formFactors = [ "headset" "headphone" ];
    };
  };

  # boot.kernelPatches = [
  #   {
  #     name = "mediatek-mt7927-bluetooth";
  #     patch = pkgs.writeText "mt7927-bt.patch" ''
  #       --- a/drivers/bluetooth/btusb.c
  #       +++ b/drivers/bluetooth/btusb.c
  #       @@ -672,6 +672,8 @@ static const struct usb_device_id quirks_table[] = {
  #        	{ USB_DEVICE(0x0489, 0xe0e4), .driver_info = BTUSB_MEDIATEK |
  #        						     BTUSB_WIDEBAND_SPEECH },
  #        	{ USB_DEVICE(0x0489, 0xe0f1), .driver_info = BTUSB_MEDIATEK |
  #       +						     BTUSB_WIDEBAND_SPEECH },
  #       +	{ USB_DEVICE(0x0489, 0xe13a), .driver_info = BTUSB_MEDIATEK |
  #        						     BTUSB_WIDEBAND_SPEECH },
  #        	{ USB_DEVICE(0x0489, 0xe0f2), .driver_info = BTUSB_MEDIATEK |
  #        						     BTUSB_WIDEBAND_SPEECH },
  #     '';
  #   }
  # ];

  networking.hostId = "8a9c7614";
  networking.hostName = cfg-meta.hostname;
  networking.domain = "home.7mind.io";
  networking.useDHCP = false;
  networking.firewall = {
    allowedTCPPorts = [ 8234 ];
  };

  smind.gaming.steam.enable = true;

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
        "ollama"
      ];
    };

  };

  home-manager.users.pavel = import ./home-pavel.nix;
  home-manager.users.root = import ./home-root.nix;


  # services.sillytavern = {
  #   enable = true;
  #   port = 8045;
  #   whitelist = false;
  #   configFile =
  #     let
  #       config = ((pkgs.formats.yaml { }).generate "config.yaml" {
  #         api = {
  #           ollama = {
  #             enabled = true;
  #             api_url = "http://127.0.0.1:11434/v1";
  #             api_key = "";
  #             default_model = "huihui_ai/phi4-abliterated:14b";
  #             prompt_template = "alpaca";
  #             max_context_length = 32768;
  #             temperature = 0.7;
  #             top_p = 0.9;
  #             top_k = 40;
  #           };
  #         };


  #         dataRoot = "./data";
  #         listen = false;
  #         listenAddress = {
  #           ipv4 = "0.0.0.0";
  #           ipv6 = "[::]";
  #         };
  #         protocol = {
  #           ipv4 = true;
  #           ipv6 = false;
  #         };
  #         dnsPreferIPv6 = false;
  #         browserLaunch = {
  #           enabled = true;
  #           browser = "default";
  #           hostname = "auto";
  #           port = -1;
  #           avoidLocalhost = false;
  #         };
  #         port = 8000;
  #         ssl = {
  #           enabled = false;
  #           certPath = "./certs/cert.pem";
  #           keyPath = "./certs/privkey.pem";
  #           keyPassphrase = "";
  #         };
  #         whitelistMode = true;
  #         enableForwardedWhitelist = true;
  #         whitelist = [
  #           "::1"
  #           "127.0.0.1"
  #         ];
  #         whitelistDockerHosts = true;
  #         basicAuthMode = false;
  #         basicAuthUser = {
  #           username = "user";
  #           password = "password";
  #         };
  #         enableCorsProxy = false;
  #         requestProxy = {
  #           enabled = false;
  #           url = "socks5://username:password@example.com:1080";
  #           bypass = [
  #             "localhost"
  #             "127.0.0.1"
  #           ];
  #         };
  #         enableUserAccounts = false;
  #         enableDiscreetLogin = false;
  #         perUserBasicAuth = false;
  #         sso = {
  #           autheliaAuth = false;
  #           authentikAuth = false;
  #         };
  #         hostWhitelist = {
  #           enabled = false;
  #           scan = true;
  #           hosts = [

  #           ];
  #         };
  #         sessionTimeout = -1;
  #         disableCsrfProtection = false;
  #         securityOverride = false;
  #         logging = {
  #           enableAccessLog = true;
  #           minLogLevel = 0;
  #         };
  #         rateLimiting = {
  #           preferRealIpHeader = false;
  #         };
  #         backups = {
  #           common = {
  #             numberOfBackups = 50;
  #           };
  #           chat = {
  #             enabled = true;
  #             checkIntegrity = true;
  #             maxTotalBackups = -1;
  #             throttleInterval = 10000;
  #           };
  #         };
  #         thumbnails = {
  #           enabled = true;
  #           format = "jpg";
  #           quality = 95;
  #           dimensions = {
  #             bg = [
  #               160
  #               90
  #             ];
  #             avatar = [
  #               96
  #               144
  #             ];
  #             persona = [
  #               96
  #               144
  #             ];
  #           };
  #         };
  #         performance = {
  #           lazyLoadCharacters = false;
  #           memoryCacheCapacity = "100mb";
  #           useDiskCache = true;
  #         };
  #         cacheBuster = {
  #           enabled = false;
  #           userAgentPattern = "";
  #         };
  #         allowKeysExposure = false;
  #         skipContentCheck = false;
  #         whitelistImportDomains = [
  #           "localhost"
  #           "cdn.discordapp.com"
  #           "files.catbox.moe"
  #           "raw.githubusercontent.com"
  #           "char-archive.evulid.cc"
  #         ];
  #         requestOverrides = [

  #         ];
  #         extensions = {
  #           enabled = true;
  #           autoUpdate = true;
  #           models = {
  #             autoDownload = true;
  #             classification = "Cohee/distilbert-base-uncased-go-emotions-onnx";
  #             captioning = "Xenova/vit-gpt2-image-captioning";
  #             embedding = "Cohee/jina-embeddings-v2-base-en";
  #             speechToText = "Xenova/whisper-small";
  #             textToSpeech = "Xenova/speecht5_tts";
  #           };
  #         };
  #         enableDownloadableTokenizers = true;
  #         promptPlaceholder = "[Start a new chat]";
  #         openai = {
  #           randomizeUserId = false;
  #           captionSystemPrompt = "";
  #         };
  #         deepl = {
  #           formality = "default";
  #         };
  #         mistral = {
  #           enablePrefix = false;
  #         };
  #         ollama = {
  #           keepAlive = -1;
  #           batchSize = -1;
  #         };
  #         claude = {
  #           enableSystemPromptCache = false;
  #           cachingAtDepth = -1;
  #           extendedTTL = false;
  #         };
  #         gemini = {
  #           apiVersion = "v1beta";
  #         };
  #         enableServerPlugins = false;
  #         enableServerPluginsAutoUpdate = true;


  #       });
  #     in
  #     "${config}";
  # };
}
