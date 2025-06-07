{ config, lib, pkgs, cfg-const, ... }:

{
  options = {
    smind.environment.linux.sane-defaults.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "";
    };
  };

  config =
    (lib.mkIf config.smind.environment.linux.sane-defaults.enable
      {
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


        programs.ssh = {
          startAgent = true;
        };

        environment = {
          enableDebugInfo = true;
          shellAliases = cfg-const.universal-aliases;
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

          # mail
          mailutils

        ];

        services.fstrim.enable = true;
        services.fwupd.enable = true;

        services.journald.extraConfig = ''
          MaxRetentionSec=1month
        '';
      });


}

