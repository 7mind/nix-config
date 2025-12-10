{ config, lib, pkgs, cfg-meta, ... }:

{
  options = {
    smind.bootloader.ipxe.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Add iPXE chainload entry to systemd-boot menu";
    };
  };

  config = lib.mkIf (
    config.smind.bootloader.ipxe.enable
    && config.boot.loader.systemd-boot.enable
    && pkgs.lib.hasPrefix "x86_64" cfg-meta.arch
  ) {
    boot.loader.systemd-boot = {
      extraFiles = {
        "EFI/ipxe/ipxe.efi" = "${pkgs.ipxe}/ipxe.efi";
      };

      extraEntries = {
        "ipxe.conf" = ''
          title iPXE Network Boot
          efi /EFI/ipxe/ipxe.efi
        '';
      };
    };
  };
}
