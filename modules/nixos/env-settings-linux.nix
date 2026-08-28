{ config, lib, pkgs, cfg-const, ... }:

{
  options = {
    smind.environment.linux.sane-defaults.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable common Linux system packages and settings";
    };
    smind.environment.linux.serial-debug.enable = lib.mkEnableOption "serial console debug output";
    smind.environment.linux.fwupd.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install fwupd firmware update tools";
    };
  };

  config = lib.mkMerge [
    {
      environment.systemPackages = [ pkgs.lsscsi ];

      # Don't force-import the root pool (the new default in nixpkgs 26.11).
      # Set here rather than in modules/nixos/zfs.nix so the PXE seeds in
      # private/hosts/vm/pxe/ pick it up too — they import this module but
      # skip the smind.zfs option set. Inert when ZFS isn't enabled;
      # mkDefault keeps host-level forceImport=true overrides cheap.
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
        ghostty-terminfo
        ncurses # for generic terminfo

        nixpkgs-fmt
        nix-converter
        nix-ld
        nixos-firewall-tool

        gptfdisk
        parted
        nvme-cli
        partclone
        smartmontools
        cryptsetup
        squashfsTools
        squashfuse

        efibootmgr

        pstree
        inotify-tools
        lsof
        reptyr

        pciutils
        usbutils
      ] ++ lib.optional config.smind.environment.linux.fwupd.enable fwupd ++ [
        lm_sensors

        bridge-utils
        ethtool
        cifs-utils
        inetutils # telnet, etc

        spectre-meltdown-checker
        pax-utils
        sbctl

        macchina
        hyfetch
        inxi
        lshw
        hwinfo
        dmidecode

        dool
        iotop
        powertop
        powerstat

        stress

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
