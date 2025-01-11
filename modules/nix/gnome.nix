{ config, lib, pkgs, ... }:

{
  options = {
    smind.desktop.gnome.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.desktop.gnome.enable {
    environment.sessionVariables = {
      GTK_THEME = "Adwaita:dark";

      #QT_QPA_PLATFORMTHEME = "gnome"; # this breaks Telegram systray icon
      QT_QPA_PLATFORMTHEME = "qgnomeplatform"; # qt.platformTheme is broken, this fixes it

      QT_AUTO_SCREEN_SCALE_FACTOR = "1";
      QT_ENABLE_HIGHDPI_SCALING = "1";
      QT_QPA_PLATFORM = "wayland";
    };

    # see https://github.com/NixOS/nixpkgs/issues/372802
    # an SSH key must have corresponding .pub in order to be recognised by keychain ( ssh-keygen -y -f ~/.ssh/id_ed25519 > ~/.ssh/id_ed25519.pub )
    programs.seahorse.enable = true;

    programs.ssh = {
      startAgent = true;
      enableAskPassword = true;

      # ssh ignores SSH_ASKPASS if it detects a TTY, workaround:
      # setsid ssh-add < /dev/null
      #askPassword =
      #  lib.mkForce "${pkgs.seahorse}/libexec/seahorse/ssh-askpass";
    };

    security.polkit.enable = true;

    qt =
      {
        enable = true;
        #platformTheme = "qgnomeplatform"; # cannot be assigned, nixpkgs bug
        #platformTheme = "gnome"; # this breaks Telegram systray icon
        platformTheme = null;
        style = "adwaita-dark";
      };

    # https://github.com/NixOS/nixpkgs/issues/33277#issuecomment-639281657
    # https://github.com/NixOS/nixpkgs/issues/114514
    services.xserver.desktopManager.gnome = {
      enable = true;
      # extraGSettingsOverridePackages = [ pkgs.mutter ];
      # extraGSettingsOverrides = ''
      #   [org.gnome.mutter]
      #   experimental-features=['scale-monitor-framebuffer', 'xwayland-native-scaling']
      #   [org.gnome.mutter.wayland]
      #   xwayland-allow-grabs=true
      #   xwayland-grab-access-rules=['parsecd']
      # '';
    };


    services.gvfs.enable = true;
    
    services.udev.packages = [ pkgs.gnome-settings-daemon ];

    services.xserver.enable = true;
    services.xserver.displayManager.gdm.enable = true;

    security.pam = {
      services = {
        login.enableGnomeKeyring = true;
        sddm.enableGnomeKeyring = true;
        lightdm.enableGnomeKeyring = true;
        greetd.enableGnomeKeyring = true;
        gdm.enableGnomeKeyring = true;
      };
    };

    environment.systemPackages = (with pkgs.gnomeExtensions; [
      appindicator
    ]) ++ (with pkgs; [
      dconf-editor
      seahorse
    ]);

    services.gnome = {
      gnome-settings-daemon.enable = true;
      core-utilities.enable = true;
      core-os-services.enable = true;
      core-shell.enable = true;
      core-developer-tools.enable = true;
      sushi.enable = true;
      gnome-remote-desktop.enable = true;
      gnome-keyring.enable = true;
    };

    programs.gnome-terminal.enable = true;
    programs.gnome-disks.enable = true;
    programs.file-roller.enable = true;

    environment.gnome.excludePackages = with pkgs; [
      orca # text to speech
      epiphany
      gnome-text-editor
      gnome-calculator
      gnome-calendar
      gnome-characters
      gnome-clocks
      gnome-console
      gnome-contacts
      gnome-font-viewer
      gnome-logs
      gnome-maps
      gnome-music
      gnome-weather
      totem
      yelp
      gnome-tour
      gnome-user-docs
      simple-scan
    ];
  };
}
