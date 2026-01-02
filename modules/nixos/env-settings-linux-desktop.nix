{ config, lib, pkgs, ... }:

{
  options = {
    smind.environment.linux.sane-defaults.desktop.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind ? "isDesktop" && config.smind.isDesktop;
      description = "Enable desktop-specific Linux packages (Vulkan, clipboard tools)";
    };
  };

  config =
    (lib.mkIf config.smind.environment.linux.sane-defaults.desktop.enable {
      environment.systemPackages = with pkgs; [
        vulkan-tools
        mesa-demos # ex glxinfo
        clinfo

        wl-clipboard
        extract-initrd # not the best place, but we need to do some extra job to expose it into pxe

        yt-dlp
        brightnessctl
        mission-center
        nvtopPackages.full


        # neohtop # broken
        # vkmark
      ];

      environment.shellAliases = {
        pbcopy =
          "${pkgs.wl-clipboard}/bin/wl-copy";
        pbpaste =
          "${pkgs.wl-clipboard}/bin/wl-paste";
      };
    });
}

