{ config, lib, pkgs, ... }:

{
  options = {
    smind.environment.linux.sane-defaults.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "";
    };
  };

  config = lib.mkIf config.smind.environment.linux.sane-defaults.enable {
    boot = {
      tmp.useTmpfs = true;
      tmp.cleanOnBoot = true;
    };

    security.pam = {
      loginLimits = [
        {
          domain = "*";
          item = "nofile";
          type = "hard";
          value = "524288";
        }
        {
          domain = "*";
          item = "nofile";
          type = "soft";
          value = "524288";
        }
      ];
    };

    environment = {
      enableDebugInfo = true;

      shellAliases = {
        lsblk =
          "lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINT,FSUSE%,WWN,SERIAL,MODEL";
        watch = "viddy";
        tree = "lsd --tree";
        ls = "lsd -lh --group-directories-first";
        la = "lsd -lha --group-directories-first";

        myip = "curl -4 ifconfig.co";
        myip4 = "curl -4 ifconfig.co";
        myip6 = "curl -6 ifconfig.co";
      };

    };

    environment.systemPackages = with pkgs; [
      # terminal
      kitty.terminfo

      # file managers
      far2l

      # editors

      # nix tools
      nixpkgs-fmt
      nix-ld-rs

      # disk tools
      gptfdisk
      parted
      nvme-cli
      partclone
      smartmontools
      cryptsetup
      squashfsTools
      squashfuse

      # efi tools
      efibootmgr

      # system tools
      pstree
      inotify-tools
      lsof

      # hw tools
      pciutils
      usbutils
      fwupd

      # networking
      bridge-utils
      ethtool
      cifs-utils

      # security
      spectre-meltdown-checker
      pax-utils
      sbctl

      # system info
      fastfetch
      inxi
      lshw
      hwinfo
      dmidecode

      # monitoring
      #dstat # unmaintained, dead
      dool
      iotop
      powertop

      # benchmark
      stress

    ];

    services.fstrim.enable = true;
    services.fwupd.enable = true;

    services.journald.extraConfig = ''
      MaxRetentionSec=1month
    '';
  };
}
