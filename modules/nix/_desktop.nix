{ config, lib, ... }:

{
  options = {
    smind.roles.desktop.generic-gnome = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.roles.desktop.generic-gnome {
    smind = {
      environment.sane-defaults.enable = true;
      environment.linux.sane-defaults.enable = true;
      environment.alien-filesystems.enable = true;
      environment.cups.enable = true;


      zram-swap = true;
      zsh.enable = true;
      nix.customize = true;

      zfs.enable = true;

      router.enable = true;

      locale.ie.enable = true;
      kernel.sane-defaults.enable = true;
      power-management.enable = true;



      grub.efi.enable = true;
      fonts.nerd.enable = true;
      fonts.apple.enable = true;

      nix-ld.enable = true;
      desktop.gnome.enable = true;
      desktop.gnome.minimal-hotkeys = true;
      home-manager.enable = true;
      keyboard.super-remap.enable = true;

      vm.virt-manager.enable = true;
    };
  };
}
