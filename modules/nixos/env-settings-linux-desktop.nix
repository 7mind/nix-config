{ config, lib, pkgs, ... }:

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
        mission-center
        nvtopPackages.full

        libnotify # notify-send command

        # neohtop # broken
        # vkmark
      ];

      programs.obs-studio = {
        enable = true;
        enableVirtualCamera = true;
        plugins = with pkgs.obs-studio-plugins; [
          wlrobs
          input-overlay
          obs-mute-filter
          obs-source-record
          obs-backgroundremoval
          obs-pipewire-audio-capture
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
      };
    })
  ];
}
