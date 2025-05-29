{ config, lib, pkgs, ... }:

{
  options = {
    smind.environment.linux.sane-defaults.desktop.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind ? "isDesktop" && config.smind.isDesktop;
      description = "";
    };
  };

  config =
    (lib.mkIf config.smind.environment.linux.sane-defaults.desktop.enable {
      environment.systemPackages = with pkgs; [
        vulkan-tools
        glxinfo
        clinfo

        wl-clipboard

        neohtop
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

