{
  config,
  lib,
  pkgs,
  cfg-meta,
  ...
}:

let
  bootEntryLimit = 8;
  configurationLimit = config.smind.bootloader.configurationLimit;
in
{
  options = {
    smind.bootloader.configurationLimit = lib.mkOption {
      type = lib.types.ints.positive;
      default = bootEntryLimit;
      description = "Maximum number of boot entries to keep for Linux bootloaders.";
    };
    smind.bootloader.systemd-boot.enable = lib.mkEnableOption "systemd-boot as EFI bootloader";
  };

  config = lib.mkMerge [
    {
      boot.loader.grub.configurationLimit = lib.mkDefault configurationLimit;
      boot.loader.systemd-boot.configurationLimit = lib.mkDefault configurationLimit;
      boot.lanzaboote.settings.configurationLimit = lib.mkDefault configurationLimit;
    }
    (lib.mkIf config.smind.bootloader.systemd-boot.enable {
      boot.loader = {
        grub.enable = lib.mkForce false;
        efi.efiSysMountPoint = "/boot";
        timeout = 2;
        systemd-boot = {
          enable = true;
          memtest86.enable = pkgs.lib.hasPrefix "x86_64" cfg-meta.arch;
          edk2-uefi-shell.enable = true;
          consoleMode = "max";
        };
      };
    })
  ];
}
