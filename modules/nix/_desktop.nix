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
    assertions = [ ];

    smind = {
      zram-swap = true;
      zsh.enable = true;
      nix.customize = true;

      zfs.enable = true;

      router.enable = true;

      locale.ie.enable = true;
      kernel.sane-defaults.enable = true;
      power-management.enable = true;
      environment.sane-defaults.enable = true;
      grub.efi.enable = true;
      fonts.nerd.enable = true;
      fonts.apple.enable = true;

      desktop.gnome.enable = true;
      desktop.gnome.minimal-hotkeys = true;
    };
  };
}
