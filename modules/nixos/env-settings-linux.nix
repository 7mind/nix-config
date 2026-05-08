{ config, lib, pkgs, cfg-const, ... }:

{
  options = {
    smind.environment.linux.sane-defaults.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable common Linux system packages and settings";
    };
    smind.environment.linux.serial-debug.enable = lib.mkEnableOption "serial console debug output";
  };

  config = lib.mkMerge [
    {
      environment.systemPackages = [ pkgs.lsscsi ];

      # Default for ZFS hosts: don't force-import the root pool. This
      # is the new default in nixpkgs 26.11, and emitting it here
      # rather than in modules/nixos/zfs.nix means the PXE seeds in
      # private/hosts/vm/pxe/ pick it up too — they import this
      # module via (cfg-meta.generic-linux-module) but skip the
      # smind.zfs option set, so they wouldn't otherwise see the
      # default. mkDefault keeps host-level overrides cheap if
      # forceImport=true is ever needed (rare).
      #
      # Setting unconditionally is safe: when ZFS isn't enabled
      # (no `boot.supportedFilesystems = ["zfs"]`), the option is
      # inert.
      boot.zfs.forceImportRoot = lib.mkDefault false;
    }

    (lib.mkIf config.smind.environment.linux.sane-defaults.enable {
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
        shellAliases = cfg-const.universal-aliases;
      };

      programs.firejail.enable = true;

      environment.systemPackages = with pkgs; [
        # terminal support
        ghostty-terminfo
        ncurses # for generic terminfo

        # nix tools
        nixpkgs-fmt
        nix-converter
        nix-ld
        nixos-firewall-tool

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
        reptyr

        # hw tools
        pciutils
        usbutils
        fwupd
        lm_sensors

        # networking
        bridge-utils
        ethtool
        cifs-utils
        inetutils # telnet, etc

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
        powerstat

        # benchmark
        stress

        # mail
        mailutils
      ];

      services.fstrim.enable = true;

      services.journald.extraConfig = ''
        MaxRetentionSec=1month
      '';
    })

    (lib.mkIf config.smind.environment.linux.serial-debug.enable {
      boot.consoleLogLevel = 7;
      boot.kernelParams = [
        "console=tty0"
        "console=ttyS0,115200n8"
        "loglevel=7"
        "rd.debug"
        "rd.udev.log_priority=debug"
        "panic=60"
      ];
      systemd.services."serial-getty@ttyS0".enable = true;
    })
  ];
}
