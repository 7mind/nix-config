{ config, lib, ... }:

let
  isDesktopRole = config.smind.roles.desktop.generic-gnome
    || config.smind.roles.desktop.generic-cosmic;
in
{
  options = {
    smind.isDesktop = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host is a desktop system";
    };

    smind.isLaptop = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host is a laptop (enables hibernate, suspend, etc.)";
    };

    smind.roles.desktop.generic-gnome = lib.mkEnableOption "GNOME-based desktop role with full defaults";

    smind.roles.desktop.generic-cosmic = lib.mkEnableOption "COSMIC-based desktop role with full defaults";
  };

  config = lib.mkMerge [
    # Common desktop settings (shared by all desktop roles)
    (lib.mkIf isDesktopRole {
      # Disable IBus - not needed and causes issues on Wayland (especially COSMIC)
      # GNOME enables it by default, but we don't use CJK input methods
      i18n.inputMethod.enable = false;

      # Kill session processes (GUI apps) on logout
      # This does NOT affect systemd user services or lingering - only session-scoped processes
      services.logind.settings.Login.KillUserProcesses = true;

      # Disable automatic suspend on idle for non-laptop desktops
      services.logind.settings.Login.IdleAction = lib.mkIf (!config.smind.isLaptop) "ignore";

      smind = {
        isDesktop = lib.mkDefault true;

        # Load owner-specific secrets (SSH keys, API tokens, etc.) on desktops
        age.load-owner-secrets = lib.mkDefault true;

        hw.ledger.enable = lib.mkDefault false;
        hw.trezor.enable = lib.mkDefault false;
        hw.uhk-keyboard.enable = lib.mkDefault false;
        locale.ie.enable = lib.mkDefault false;
        security.sudo.wheel-permissive-rules = lib.mkDefault false;
        security.sudo.wheel-passwordless = lib.mkDefault false;
        zfs.initrd-unlock.enable = lib.mkDefault false;

        environment.sane-defaults.enable = lib.mkDefault true;
        environment.linux.sane-defaults.enable = lib.mkDefault true;
        environment.linux.sane-defaults.desktop.enable = lib.mkDefault true;
        environment.alien-filesystems.enable = lib.mkDefault true;
        environment.cups.enable = lib.mkDefault true;
        environment.all-docs.enable = lib.mkDefault true;
        environment.nix-ld.enable = lib.mkDefault true;

        zram-swap.enable = lib.mkDefault true;

        shell.zsh.enable = lib.mkDefault true;
        shell.nushell.enable = lib.mkDefault false;

        nix.customize = lib.mkDefault true;

        zfs.enable = lib.mkDefault true;

        net.router.enable = lib.mkDefault true;
        net.enable = lib.mkDefault true;
        net.desktop.enable = lib.mkDefault true;

        kernel.sane-defaults.enable = lib.mkDefault true;
        power-management.enable = lib.mkDefault true;

        bootloader.grub.enable = lib.mkDefault false;
        bootloader.systemd-boot.enable = lib.mkDefault true;
        bootloader.lanzaboote.enable = lib.mkDefault false;

        fonts.nerd.enable = lib.mkDefault true;
        fonts.apple.enable = lib.mkDefault true;

        home-manager.enable = lib.mkDefault true;
        vm.virt-manager.enable = lib.mkDefault true;
        smartd.enable = lib.mkDefault true;
      };
    })

    # GNOME-specific settings
    (lib.mkIf config.smind.roles.desktop.generic-gnome {
      smind = {
        desktop.gnome.enable = lib.mkDefault true;
        desktop.gnome.minimal-hotkeys = lib.mkDefault true;
        keyboard.super-remap.enable = lib.mkDefault true;
        keyboard.super-remap.kanata-switcher.enable = lib.mkDefault true;
      };
    })

    # COSMIC-specific settings
    (lib.mkIf config.smind.roles.desktop.generic-cosmic {
      smind.desktop.cosmic.enable = lib.mkDefault true;
    })
  ];
}
