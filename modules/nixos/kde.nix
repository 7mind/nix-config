{ config, lib, pkgs, ... }:

{
  options = {
    smind.desktop.kde.enable = lib.mkEnableOption "KDE Plasma 6 desktop environment with SDDM";
    smind.desktop.kde.mime.enable = lib.mkEnableOption "Associate KDE Applications with document MIME Types";
    smind.desktop.kde.kde-gtk-config.enable = lib.mkEnableOption "Allow overwriting GTK settings with kde-gtk-config";
    smind.desktop.kde.dconf.profile = lib.mkOption {
      type = lib.types.str;
      default = "kde";
      description = "Dconf profile name for KDE session. (`kde` instead of `user` by default to not conflict with GNOME settings)";
    };
  };

  config = lib.mkIf config.smind.desktop.kde.enable {
    programs.dconf = {
      enable = true;
      profiles.${config.smind.desktop.kde.dconf.profile}.databases = [
        {
          lockAll = false;
          settings = { };
        }
      ];
    };

    services.desktopManager.plasma6 = {
      enable = true;
      enableQt5Integration = true;
    };

    # Disable orca to avoid conflict with GNOME module when both desktops enabled
    services.orca.enable = lib.mkForce false;

    # Display manager (SDDM) configuration handled by display-manager.nix module

    smind.security.keyring = {
      enable = true;
      backend = "kwallet";
      sshAgent = "none";
      displayManagers = [ "login" "sddm" "greetd" "gdm" "gdm-password" "gdm-fingerprint" "gdm-autologin" ];
    };

    smind.desktop.wayland.session-variables.enable = true;

    xdg.portal.enable = true;

    programs.partition-manager.enable = true;

    programs.firefox.nativeMessagingHosts.packages = [
      pkgs.kdePackages.plasma-browser-integration
    ];

    environment.systemPackages = with pkgs; [
      kdePackages.kate
      kdePackages.kwalletmanager
      kdePackages.okular
      kdePackages.gwenview
      krusader
      kdePackages.ark
      kdePackages.spectacle
      kdePackages.filelight
      kdePackages.kaddressbook
      krita
      krename
      kdiff3

      gsettings-qt

      kdePackages.kcalutils
      kdePackages.networkmanager-qt
      kdePackages.kdegraphics-thumbnailers

      kdePackages.akonadi
      kdePackages.akonadi-calendar
      kdePackages.akonadi-contacts
      kdePackages.akonadi-import-wizard
      kdePackages.akonadi-mime
      kdePackages.akonadi-search
      kdePackages.akonadiconsole

      kdePackages.kaccounts-integration
      kdePackages.incidenceeditor
      kdePackages.plasma-wayland-protocols
      kdePackages.dolphin-plugins
      kdePackages.kio-extras
      kdePackages.kdenetwork-filesharing
      kdePackages.calendarsupport
      kdePackages.print-manager
      kdePackages.kontact
      kdePackages.korganizer
      kdePackages.eventviews
      kdePackages.ffmpegthumbs
      kdePackages.kdepim-runtime
      kdePackages.kdepim-addons
      kdePackages.krdc

      (lib.mkIf config.smind.desktop.kde.kde-gtk-config.enable kdePackages.kde-gtk-config)

      kdePackages.kio
      kdePackages.kio-extras
      kdePackages.kio-fuse
      kdePackages.kio-admin
    ];

    environment.plasma6.excludePackages = with pkgs; [
      orca
#      kdePackages.elisa
#      kdePackages.oxygen
#      kdePackages.khelpcenter
#      kdePackages.konsole
#      kdePackages.plasma-browser-integration
    ];

    xdg.mime.defaultApplications = lib.mkIf config.smind.desktop.kde.mime.enable {
      "application/pdf" = "okularApplication_pdf.desktop";
      "inode/directory" = "org.kde.dolphin.desktop";
      "image/jpeg" = "org.kde.gwenview.desktop";
      "image/avif" = "org.kde.gwenview.desktop";
      "image/gif" = "org.kde.gwenview.desktop";
      "image/heif" = "org.kde.gwenview.desktop";
      "image/jxl" = "org.kde.gwenview.desktop";
      "image/png" = "org.kde.gwenview.desktop";
      "image/bmp" = "org.kde.gwenview.desktop";
      "image/x-eps" = "org.kde.gwenview.desktop";
      "image/x-icns" = "org.kde.gwenview.desktop";
      "image/x-ico" = "org.kde.gwenview.desktop";
      "image/x-portable-bitmap" = "org.kde.gwenview.desktop";
      "image/x-portable-graymap" = "org.kde.gwenview.desktop";
      "image/x-portable-pixmap" = "org.kde.gwenview.desktop";
      "image/x-xbitmap" = "org.kde.gwenview.desktop";
      "image/x-xpixmap" = "org.kde.gwenview.desktop";
      "image/tiff" = "org.kde.gwenview.desktop";
      "image/x-psd" = "org.kde.gwenview.desktop";
      "image/x-webp" = "org.kde.gwenview.desktop";
      "image/webp" = "org.kde.gwenview.desktop";
      "image/x-tga" = "org.kde.gwenview.desktop";
      "application/x-krita" = "org.kde.gwenview.desktop";
      "image/x-kde-raw" = "org.kde.gwenview.desktop";
      "image/x-canon-cr2" = "org.kde.gwenview.desktop";
      "image/x-canon-crw" = "org.kde.gwenview.desktop";
      "image/x-kodak-dcr" = "org.kde.gwenview.desktop";
      "image/x-adobe-dng" = "org.kde.gwenview.desktop";
      "image/x-kodak-k25" = "org.kde.gwenview.desktop";
      "image/x-kodak-kdc" = "org.kde.gwenview.desktop";
      "image/x-minolta-mrw" = "org.kde.gwenview.desktop";
      "image/x-nikon-nef" = "org.kde.gwenview.desktop";
      "image/x-olympus-orf" = "org.kde.gwenview.desktop";
      "image/x-pentax-pef" = "org.kde.gwenview.desktop";
      "image/x-fuji-raf" = "org.kde.gwenview.desktop";
      "image/x-panasonic-rw" = "org.kde.gwenview.desktop";
      "image/x-sony-sr2" = "org.kde.gwenview.desktop";
      "image/x-sony-srf" = "org.kde.gwenview.desktop";
      "image/x-sigma-x3f" = "org.kde.gwenview.desktop";
      "image/x-sony-arw" = "org.kde.gwenview.desktop";
      "image/x-panasonic-rw2" = "org.kde.gwenview.desktop";
    };
  };
}
