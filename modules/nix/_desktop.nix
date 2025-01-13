{ config, lib, ... }:

{
  options = {
    smind.isDesktop = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };

    smind.roles.desktop.generic-gnome = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.roles.desktop.generic-gnome {
    smind = {
      isDesktop = lib.mkDefault true;

      hw.ledger.enable = lib.mkDefault false;
      hw.trezor.enable = lib.mkDefault false;
      hw.uhk-keyboard.enable = lib.mkDefault false;
      locale.ie.enable = lib.mkDefault false;
      ssh.permissive = lib.mkDefault false;
      ssh.safe = lib.mkDefault false;
      security.sudo.wheel-permissive-rules = lib.mkDefault false;
      security.sudo.wheel-passwordless = lib.mkDefault false;
      zfs.initrd-unlock.enable = lib.mkDefault false;

      environment.sane-defaults.enable = lib.mkDefault true;
      environment.linux.sane-defaults.enable = lib.mkDefault true;
      environment.alien-filesystems.enable = lib.mkDefault true;
      environment.cups.enable = lib.mkDefault true;
      environment.all-docs.enable = lib.mkDefault true;

      zram-swap = lib.mkDefault true;
      zsh.enable = lib.mkDefault true;
      nix.customize = lib.mkDefault true;

      zfs.enable = lib.mkDefault true;

      router.enable = lib.mkDefault true;

      kernel.sane-defaults.enable = lib.mkDefault true;
      power-management.enable = lib.mkDefault true;

      grub.efi.enable = lib.mkDefault true;
      fonts.nerd.enable = lib.mkDefault true;
      fonts.apple.enable = lib.mkDefault true;

      nix-ld.enable = lib.mkDefault true;
      desktop.gnome.enable = lib.mkDefault true;
      desktop.gnome.minimal-hotkeys = lib.mkDefault true;
      home-manager.enable = lib.mkDefault true;
      keyboard.super-remap.enable = lib.mkDefault true;

      vm.virt-manager.enable = lib.mkDefault true;
      net.enable = lib.mkDefault true;
      net.desktop.enable = lib.mkDefault true;
      smartd.enable = lib.mkDefault true;
    };
  };
}
