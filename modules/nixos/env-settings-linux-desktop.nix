{ config, lib, pkgs, ... }:

let
  hasNvidiaDriver = config.smind.hw.nvidia.enable;
in
{
  options = {
    smind.environment.linux.sane-defaults.desktop.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind ? "isDesktop" && config.smind.isDesktop;
      description = "Enable desktop-specific Linux packages (Vulkan, clipboard tools)";
    };

    smind.desktop.wayland.session-variables.enable = lib.mkEnableOption "Enable common Wayland session variables (Qt scaling, Electron Ozone)";

    smind.desktop.wayland.session-variables.nixos-ozone-wl.enable = lib.mkEnableOption "Enable common Wayland session variables (NixOS specific)";
  };

  config = lib.mkMerge [
    (lib.mkIf config.smind.environment.linux.sane-defaults.desktop.enable {
      environment.systemPackages = with pkgs; [
        vulkan-tools
        mesa-demos # ex glxinfo
        clinfo

        # X11 / WL diagnostics
        xlsclients
        wev
        evtest
        evtest-qt

        wl-clipboard
        extract-initrd # not the best place, but we need to do some extra job to expose it into pxe

        yt-dlp
        brightnessctl
        # External-monitor brightness/contrast/input-source over DDC/CI
        # via /dev/i2c-*. i2c-dev + the `i2c` group are wired
        # host-wide in modules/nixos/i2c.nix; the owner is already a
        # member.
        ddcutil
        mission-center
        nvtopPackages.full

        libnotify # notify-send command

        pulsemeeter
        # neohtop # broken
        # vkmark
        d-spy # needs gtk!!!
      ];

      programs.obs-studio = {
        enable = true;
        enableVirtualCamera = true;
        package = pkgs.obs-studio.override {
          cudaSupport = hasNvidiaDriver;
        };
        plugins = with pkgs.obs-studio-plugins; [
          wlrobs
          input-overlay
          obs-mute-filter
          obs-source-record
          obs-backgroundremoval
          obs-pipewire-audio-capture
          obs-gstreamer
          obs-vaapi
        ];
      };

      environment.shellAliases = {
        pbcopy =
          "${pkgs.wl-clipboard}/bin/wl-copy";
        pbpaste =
          "${pkgs.wl-clipboard}/bin/wl-paste";
      };
    })

    (lib.mkIf config.smind.desktop.wayland.session-variables.enable {
      environment.sessionVariables = {
        QT_AUTO_SCREEN_SCALE_FACTOR = "1";
        QT_ENABLE_HIGHDPI_SCALING = "1";
        QT_QPA_PLATFORM = "wayland";

        # Electron apps: use native Wayland instead of XWayland
        ELECTRON_OZONE_PLATFORM_HINT = "wayland";

        NIXOS_OZONE_WL = lib.mkIf config.smind.desktop.wayland.session-variables.nixos-ozone-wl.enable "1";

        # Make the common GTK / desktop GSettings schemas discoverable
        # session-wide. Bare Wayland WMs (niri, sway, hyprland) ship no DE that
        # registers these, so Qt-only apps that reach for a GTK file chooser
        # (AmneziaVPN, Shotcut, ...) abort with
        # "GLib-GIO-ERROR: Settings schema 'org.gtk.Settings.FileChooser' is not
        # installed". Additive: wrapped GTK apps keep their own dirs and GIO
        # merges all entries, so this never shadows a DE's own schemas.
        GSETTINGS_SCHEMA_DIR = lib.concatMapStringsSep ":" (
          p: "${p}/share/gsettings-schemas/${p.name}/glib-2.0/schemas"
        ) [
          pkgs.gtk3
          pkgs.gsettings-desktop-schemas
        ];
      };
    })
  ];
}
